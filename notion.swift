// Sends finished work and break stretches to a Notion "Work log" database that you choose.
// Plain HTTPS to the Notion API; the API token lives only in the macOS Keychain.

import AppKit
import Security
import SwiftUI

// MARK: - Keychain

enum NotionKeychain {
    private static let service = "Hanadi Timer Notion"
    private static let account = "integration"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Read once per launch: every Keychain read can ask for permission. Self-tests never touch the Keychain.
    private static var loaded = false
    private static var value: String?
    /// Off until the timer is on screen, so a Keychain permission prompt can never hide the timer.
    static var readAllowed = false

    /// Reads the key on a background thread (a Keychain prompt blocks whoever asks), then reports on the main thread.
    static func loadInBackground(_ done: @escaping () -> Void) {
        guard !TimerModel.preview else { return }
        DispatchQueue.global(qos: .utility).async {
            let k = read()
            DispatchQueue.main.async {
                value = k
                loaded = true
                readAllowed = true
                done()
            }
        }
    }
    static var cached: String? {
        if TimerModel.preview || !readAllowed { return nil }
        if !loaded { value = read(); loaded = true }
        return value
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        value = key
        loaded = true
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
        value = nil
        loaded = true
    }
}

// MARK: - Sync

final class NotionSync: ObservableObject {
    static let shared = NotionSync(
        folder: WorkHistory.fileURL.deletingLastPathComponent(),
        defaults: .standard,
        base: URL(string: "https://api.notion.com/v1/")!,
        key: { NotionKeychain.cached })

    // Settings, kept in UserDefaults: the Work log database, the link it came from,
    // and when sending started (older history stays on this Mac only).
    private static let databaseKey = "notionDatabaseID"
    private static let linkKey = "notionLink"
    private static let sinceKey = "notionSince"
    var databaseID: String? { defaults.string(forKey: Self.databaseKey) }
    var link: String { defaults.string(forKey: Self.linkKey) ?? "" }
    private var since: Date? { defaults.object(forKey: Self.sinceKey) as? Date }

    /// The last row sent, so a stretch that follows within 3 minutes extends it instead of adding a row.
    struct LastRow: Codable {
        var kind: LogEntry.Kind
        var pageID: String
        var start: Date
        var end: Date
        var minutes: Double
        var clearNotes: Bool
    }

    private struct Store: Codable {
        var last: LastRow?
        var sent: [String] = []      // start times already handled, newest last
        var lastSent: Date?
        var through: Date?           // start of the newest handled stretch; anything older is never resent
    }

    enum Health: Equatable { case ok, retrying, keyRejected, noAccess }

    @Published private(set) var connected = false
    @Published private(set) var health: Health = .ok
    @Published private(set) var lastSent: Date?

    private let folder: URL
    private let defaults: UserDefaults
    private let base: URL
    private let key: () -> String?
    private var store = Store()
    private var pending: [LogEntry] = []
    private var busy = false
    private var retryTimer: Timer?

    private static let storeKey = "notionSync"
    private var pendingURL: URL { folder.appendingPathComponent("notion-pending.json") }

    init(folder: URL, defaults: UserDefaults, base: URL, key: @escaping () -> String?) {
        self.folder = folder
        self.defaults = defaults
        self.base = base
        self.key = key
        load()
    }

    /// Notion is an advanced extra: it counts as in use once a token or a Work log has been set up.
    var inUse: Bool { connected || databaseID != nil }

    var statusText: String {
        guard connected else { return L("notion.notConnected") }
        guard databaseID != nil else { return L("notion.needsPage") }
        switch health {
        case .keyRejected: return L("notion.keyRejected")
        case .noAccess: return L("notion.noAccess")
        case .retrying: return L("notion.retrying")
        case .ok:
            if let t = lastSent { return L("notion.connectedSent", clock(t)) }
            return L("notion.connected")
        }
    }

    // MARK: Lifecycle

    /// On launch: queue anything from the history file that hasn't gone to Notion yet, then send, and retry every 5 minutes.
    func start() {
        for e in WorkHistory.readAll() { enqueue(e, sendNow: false) }
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.flush() }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
        flush()
    }

    func connect(key k: String) {
        NotionKeychain.save(k)
        refreshConnected()
        health = .ok
        flush()
    }

    func disconnect() {
        NotionKeychain.delete()
        refreshConnected()
    }

    func refreshConnected() { connected = key() != nil }

    /// Called when a stretch closes. Once a Work log is set up, stretches queue even while offline, so nothing is lost.
    func enqueue(_ e: LogEntry, sendNow: Bool = true) {
        let k = Self.id(e.start)
        guard let since, e.start >= since, store.through.map({ e.start > $0 }) ?? true, !store.sent.contains(k),
              !pending.contains(where: { Self.id($0.start) == k }) else { return }
        pending.append(e)
        pending.sort { $0.start < $1.start }
        savePending()
        if sendNow { flush() }
    }

    // MARK: Sending

    func flush() {
        refreshConnected()
        guard !busy, let apiKey = key(), let databaseID, let e = pending.first else { return }
        // Under a minute: nothing to send, but it counts as handled.
        if e.duration < 60 { finish(e, row: nil); flush(); return }

        busy = true
        let title = { (from: Date, to: Date) in
            "\(e.kind == .work ? "Work" : "Break") · \(Self.time(from)) – \(Self.time(to))"
        }
        var request: URLRequest
        var newRow: LastRow
        if let last = store.last, last.kind == e.kind, e.start.timeIntervalSince(last.end) < 180 {
            // Extend the previous row.
            let minutes = last.minutes + e.duration / 60
            newRow = LastRow(kind: e.kind, pageID: last.pageID, start: last.start, end: e.end, minutes: minutes, clearNotes: false)
            var props: [String: Any] = [
                "Session": ["title": [["text": ["content": title(last.start, e.end)]]]],
                "End": ["date": ["start": Self.iso(e.end)]],
                "Minutes": ["number": minutes.rounded()],
            ]
            if last.clearNotes { props["Notes"] = ["rich_text": [Any]()] }
            request = makeRequest("PATCH", "pages/\(last.pageID)", ["properties": props], apiKey)
        } else {
            newRow = LastRow(kind: e.kind, pageID: "", start: e.start, end: e.end, minutes: e.duration / 60, clearNotes: false)
            let body: [String: Any] = [
                "parent": ["database_id": databaseID],
                "icon": ["type": "emoji", "emoji": e.kind == .work ? "🟢" : "☕"],
                "properties": [
                    "Session": ["title": [["text": ["content": title(e.start, e.end)]]]],
                    "Type": ["select": ["name": e.kind == .work ? "Work" : "Break"]],
                    "Start": ["date": ["start": Self.iso(e.start)]],
                    "End": ["date": ["start": Self.iso(e.end)]],
                    "Day": ["date": ["start": Self.day(e.start)]],
                    "Minutes": ["number": (e.duration / 60).rounded()],
                    "Notes": ["rich_text": [Any]()],
                ],
            ]
            request = makeRequest("POST", "pages", body, apiKey)
        }

        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let pageID = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["id"] as? String
            DispatchQueue.main.async {
                self.busy = false
                if request.httpMethod == "PATCH" && (status == 400 || status == 404) {
                    // That row was deleted or archived in Notion: stop extending it and add this stretch as a new row.
                    debugLog("notion: previous row is gone (\(status)); sending as a new row")
                    self.store.last = nil
                    self.saveStore()
                    self.flush()
                    return
                }
                guard (200..<300).contains(status) else {
                    self.health = status == 401 ? .keyRejected : (status == 403 || status == 404) ? .noAccess : .retrying
                    debugLog("notion: \(request.httpMethod ?? "") failed with \(status)")
                    return
                }
                if newRow.pageID.isEmpty { newRow.pageID = pageID ?? "" }
                self.health = .ok
                self.finish(e, row: newRow)
                self.lastSent = Date()
                self.store.lastSent = self.lastSent
                self.saveStore()
                debugLog("notion: \(request.httpMethod ?? "") ok \(e.kind.rawValue) \(Self.iso(e.start))")
                self.flush()
            }
        }.resume()
    }

    private func finish(_ e: LogEntry, row: LastRow?) {
        pending.removeFirst()
        store.sent.append(Self.id(e.start))
        if store.sent.count > 1000 { store.sent.removeFirst(store.sent.count - 1000) }
        store.through = max(store.through ?? e.start, e.start)
        if let row, !row.pageID.isEmpty { store.last = row }
        savePending()
        saveStore()
    }

    private func makeRequest(_ method: String, _ path: String, _ body: [String: Any]?, _ apiKey: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 20
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }

    // MARK: Choosing the Work log

    enum SetupError: Error { case noKey, badLink, key, access, other(Int) }

    /// The 32-character Notion ID at the end of a page or database link.
    static func notionID(from link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (URL(string: trimmed)?.path ?? trimmed).replacingOccurrences(of: "-", with: "")
        guard let r = path.range(of: "[0-9a-fA-F]{32}$", options: .regularExpression) else { return nil }
        return String(path[r]).lowercased()
    }

    /// A link to an existing Work log database is used as is; a link to a page gets a new "Work log" database inside it.
    func setUp(link: String, done: @escaping (Result<Void, SetupError>) -> Void) {
        guard let apiKey = key() else { return done(.failure(.noKey)) }
        guard let id = Self.notionID(from: link) else { return done(.failure(.badLink)) }
        send(makeRequest("GET", "databases/\(id)", nil, apiKey)) { status, _ in
            if (200..<300).contains(status) {
                self.useDatabase(id, link: link)
                return done(.success(()))
            }
            if status == 401 { return done(.failure(.key)) }
            self.send(self.makeRequest("POST", "databases", Self.workLogSchema(parentPage: id), apiKey)) { status, json in
                switch status {
                case 200..<300:
                    guard let newID = json?["id"] as? String else { return done(.failure(.other(status))) }
                    self.useDatabase(newID, link: link)
                    done(.success(()))
                case 401: done(.failure(.key))
                case 400, 403, 404: done(.failure(.access))
                default: done(.failure(.other(status)))
                }
            }
        }
    }

    private func useDatabase(_ id: String, link: String) {
        if databaseID != id { store.last = nil; saveStore() }
        defaults.set(id, forKey: Self.databaseKey)
        defaults.set(link.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.linkKey)
        if since == nil { defaults.set(Date(), forKey: Self.sinceKey) }
        health = .ok
        objectWillChange.send()
        flush()
    }

    static func workLogSchema(parentPage: String) -> [String: Any] {
        [
            "parent": ["type": "page_id", "page_id": parentPage],
            "icon": ["type": "emoji", "emoji": "⏱️"],
            "title": [["type": "text", "text": ["content": "Work log"]]],
            "properties": [
                "Session": ["title": [String: Any]()],
                "Type": ["select": ["options": [["name": "Work", "color": "green"], ["name": "Break", "color": "orange"]]]],
                "Start": ["date": [String: Any]()],
                "End": ["date": [String: Any]()],
                "Day": ["date": [String: Any]()],
                "Minutes": ["number": ["format": "number"]],
                "Hours": ["formula": ["expression": "round(prop(\"Minutes\") / 6) / 10"]],
                "Notes": ["rich_text": [String: Any]()],
            ],
        ]
    }

    private func send(_ r: URLRequest, _ done: @escaping (Int, [String: Any]?) -> Void) {
        URLSession.shared.dataTask(with: r) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(status, json) }
        }.resume()
    }

    // MARK: Storage

    private func load() {
        if let d = defaults.data(forKey: Self.storeKey), let s = try? JSONDecoder().decode(Store.self, from: d) {
            store = s
            // Older installs kept only the list of sent start times; the newest of them marks what's done.
            if store.through == nil, let newest = store.sent.compactMap(Self.isoFormatter.date(from:)).max() {
                store.through = newest
                saveStore()
            }
        }
        lastSent = store.lastSent
        if let d = try? Data(contentsOf: pendingURL), let p = try? JSONDecoder().decode([LogEntry].self, from: d) {
            pending = p
        }
        refreshConnected()
    }

    private func saveStore() {
        if let d = try? JSONEncoder().encode(store) { defaults.set(d, forKey: Self.storeKey) }
    }

    private func savePending() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(pending) { try? d.write(to: pendingURL, options: .atomic) }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }
    /// "7:02 AM", with a plain space like the rows already in Notion.
    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }
    static func id(_ d: Date) -> String { iso(d) }
    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - Connect window

struct ConnectNotionView: View {
    @ObservedObject var sync: NotionSync
    @ObservedObject private var loc = Loc.shared
    let close: () -> Void
    @State private var key = ""
    @State private var link = NotionSync.shared.link
    @State private var message = ""
    @State private var messageIsError = false
    @State private var working = false

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var linkChanged: Bool { !trimmedLink.isEmpty && (trimmedLink != sync.link || sync.databaseID == nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let logo = brandLogo {
                    Image(nsImage: logo).resizable().interpolation(.high).scaledToFit().frame(height: 30)
                }
                Text(L("connect.title")).font(raleway(.bold, 18)).foregroundStyle(Color.offWhite)
            }
            Text(L(sync.connected && sync.databaseID != nil ? "connect.introConnected" : "connect.intro"))
                .font(raleway(.medium, 12))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                SecureField(text: $key, prompt: Text(L(sync.connected ? "connect.keySaved" : "connect.keyPlaceholder"))
                    .foregroundStyle(.white.opacity(0.4))) { EmptyView() }
                    .modifier(FieldStyle())
                Button(L("connect.paste")) {
                    key = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                .buttonStyle(.plain)
                .font(raleway(.bold, 12))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(.white.opacity(0.08)))
            }

            TextField(text: $link, prompt: Text(L("connect.linkPlaceholder")).foregroundStyle(.white.opacity(0.4))) { EmptyView() }
                .modifier(FieldStyle())

            if !message.isEmpty {
                Text(message)
                    .font(raleway(.semibold, 12))
                    .foregroundStyle(messageIsError ? Color.coral : Color.turquoise)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if sync.connected {
                    Button(L("connect.disconnect")) { sync.disconnect(); message = "" }
                        .buttonStyle(.plain)
                        .font(raleway(.semibold, 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button(L("connect.cancel"), action: close)
                    .buttonStyle(.plain)
                    .font(raleway(.semibold, 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.trailing, 8)
                Button(action: save) {
                    Text(L("connect.save")).font(raleway(.bold, 13)).foregroundStyle(.white)
                        .padding(.horizontal, 20).frame(height: 32)
                        .background(Capsule().fill(Color.coral))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(working || (trimmedKey.isEmpty && !linkChanged))
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(Color(hex: 0x0B0B0B))
        .environment(\.colorScheme, .dark)
        .environment(\.layoutDirection, loc.isArabic ? .rightToLeft : .leftToRight)
    }

    private func save() {
        if !trimmedKey.isEmpty {
            sync.connect(key: trimmedKey)
            key = ""
        }
        guard linkChanged else { return close() }
        guard sync.connected else { return show(L("connect.errNoKey"), error: true) }
        working = true
        show(L("connect.working"), error: false)
        sync.setUp(link: trimmedLink) { result in
            working = false
            switch result {
            case .success:
                show(L("connect.ready"), error: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { close() }
            case .failure(let e):
                switch e {
                case .noKey: show(L("connect.errNoKey"), error: true)
                case .badLink: show(L("connect.errLink"), error: true)
                case .key: show(L("connect.errKey"), error: true)
                case .access: show(L("connect.errAccess"), error: true)
                case .other(let code): show(L("connect.errOther", code), error: true)
                }
            }
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}

private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono(12))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12)))
            .foregroundStyle(.white)
    }
}

final class ConnectNotionWindow {
    static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(white: 0.043, alpha: 1)
            w.contentView = NSHostingView(rootView: ConnectNotionView(sync: .shared) { window?.close() })
            w.setContentSize(w.contentView!.fittingSize)
            w.center()
            w.level = .floating
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Without a main menu, ⌘V and friends do nothing in text fields; the menu stays hidden for this menu-bar app.
func installEditMenu() {
    let main = NSMenu()
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main
}
