// Hanadi Timer — a floating LED desk timer in Hanadi Alotaibi's brand colors.
// Tap the screen: count up from 00:00 (tap again to pause / resume).
// Tap 10 / 20 / 40 / 60: count down. Right-click for more.

import AppKit
import SwiftUI
import ServiceManagement
import Carbon

// MARK: - Brand

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    static let coral = Color(hex: 0xFA555E)
    static let turquoise = Color(hex: 0x2ED3C6)
    static let offWhite = Color(hex: 0xF8FAFF)
    static let bodyTop = Color(hex: 0x1A1A1A)
    static let bodyBottom = Color(hex: 0x000000)
    static let screen = Color(hex: 0x050505)
    static let sand = Color(hex: 0xEFE7DC)
}

func registerBrandFonts() {
    for name in ["Raleway", "JetBrainsMono"] {
        if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

func raleway(_ weight: Font.Weight, _ size: CGFloat) -> Font { .custom("Raleway", size: size).weight(weight) }
/// Small labels: JetBrains Mono, or the system font for Arabic (a monospace fallback spreads Arabic letters apart).
func mono(_ size: CGFloat) -> Font {
    Loc.shared.isArabic ? .system(size: size + 1, weight: .semibold) : .custom("JetBrains Mono", size: size).weight(.semibold)
}

func debugLog(_ s: String) {
    if ProcessInfo.processInfo.environment["TIMER_DEBUG"] != nil { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
}

// MARK: - Permanent history

/// Every work and break stretch, kept forever (one JSON line each), unlike today's log which resets daily:
/// ~/Library/Application Support/Hanadi Timer/work-log.jsonl
enum WorkHistory {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hanadi Timer/work-log.jsonl")
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    /// Every entry in the file, oldest first.
    static func readAll() -> [LogEntry] {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let kind = (o["kind"] as? String).flatMap(LogEntry.Kind.init(rawValue:)),
                  let start = (o["start"] as? String).flatMap(iso.date(from:)),
                  let end = (o["end"] as? String).flatMap(iso.date(from:)) else { return nil }
            return LogEntry(kind: kind, start: start, end: end)
        }.sorted { $0.start < $1.start }
    }

    /// Appends entries whose start time isn't in the file yet.
    static func append(_ entries: [LogEntry]) {
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var seen = Set(existing.split(separator: "\n").compactMap { line -> String? in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return (obj["start"] as? String).flatMap { iso.date(from: $0) }.map { iso.string(from: $0) }
        })
        var out = ""
        for e in entries where e.duration >= 5 {
            let start = iso.string(from: e.start)
            guard !seen.contains(start) else { continue }
            seen.insert(start)
            let minutes = (e.duration / 60 * 10).rounded() / 10
            out += "{\"kind\":\"\(e.kind.rawValue)\",\"start\":\"\(start)\",\"end\":\"\(iso.string(from: e.end))\",\"minutes\":\(minutes)}\n"
        }
        guard !out.isEmpty else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(out.data(using: .utf8)!)
            try? h.close()
        } else {
            try? out.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Timer model

/// One stretch of work or break, kept in today's log.
struct LogEntry: Codable, Identifiable {
    enum Kind: String, Codable { case work, rest }
    var kind: Kind
    var start: Date
    var end: Date
    var id: Date { start }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// What the timer remembers when the app closes, so it picks up where it was.
private struct SavedState: Codable {
    var day: String
    var mode: String
    var presetMin: Int
    var elapsed: TimeInterval
    var onBreak: Bool
    var breakStartedAt: Date?
    var resumeAfterBreak: Bool
    var log: [LogEntry]
    /// When work was running at save time; a restart within 2 minutes (an update) keeps it running.
    var runningAt: Date?
}

final class TimerModel: ObservableObject {
    enum Mode: String { case idle, up, down, done }

    /// Previews and self-tests: no sound, nothing saved.
    static var preview = false
    /// The time; self-tests swap in a fake clock to cross midnight or be away for hours.
    static var clock: () -> Date = { Date() }
    /// Seconds since the last keyboard or mouse input (no permission needed); swapped in self-tests.
    static var idleSeconds: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
    /// Work stops counting after this long without input.
    static let idleLimit: TimeInterval = 15 * 60
    /// Self-tests watch what gets recorded.
    static var onRecord: ((LogEntry) -> Void)?
    private static let stateKey = "state"

    // The work timer.
    @Published private(set) var mode: Mode = .idle
    @Published private(set) var running = false
    @Published private(set) var presetMin = 0
    private var startedAt: Date?
    private var banked: TimeInterval = 0

    // A break sits on top of the work timer, which waits paused underneath.
    @Published private(set) var onBreak = false
    private var breakStartedAt: Date?
    private var resumeAfterBreak = false

    // Today's log.
    @Published private(set) var log: [LogEntry] = []
    private var segmentStart: Date?
    private var lastSave = TimerModel.clock()

    @Published private(set) var now = TimerModel.clock()
    @Published var volume: Int = UserDefaults.standard.object(forKey: "volume") as? Int ?? 2 {
        didSet { UserDefaults.standard.set(volume, forKey: "volume") }
    }
    @Published var brightness: Int = UserDefaults.standard.object(forKey: "brightness") as? Int ?? 2 {
        didSet { UserDefaults.standard.set(brightness, forKey: "brightness") }
    }

    private var ticker: Timer?
    private var alarm: Timer?

    // Milestone cheers: a short message in the label plus a chime.
    @Published private(set) var toast: String?
    /// Set when work was paused because you were away; the dial asks what to do with that time.
    @Published private(set) var awaySince: Date?
    private var day = TimerModel.today
    private var lastIdleCheck = Date.distantPast
    private var toastUntil = Date.distantPast
    private var cheered: Set<String> = []     // this work session; cleared on a new start
    private var dayCheered: Set<String> = []  // hours worked today

    init() {
        day = Self.today
        restore()
        rollDayIfNeeded()
        markPassedMilestones()
        updateTicker()
    }

    var elapsed: TimeInterval { banked + (startedAt.map { now.timeIntervalSince($0) } ?? 0) }
    var level: Double { [0.4, 0.7, 1.0][brightness] }

    private var breakElapsed: TimeInterval { breakStartedAt.map { now.timeIntervalSince($0) } ?? 0 }

    /// How full the ring is: time left on a countdown, the current minute when counting up or on a break.
    var progress: Double {
        if onBreak { return breakElapsed.truncatingRemainder(dividingBy: 60) / 60 }
        switch mode {
        case .idle: return 0
        case .done: return 1
        case .up: return elapsed.truncatingRemainder(dividingBy: 60) / 60
        case .down: return max(0, 1 - elapsed / Double(presetMin * 60))
        }
    }

    var shownSeconds: Int {
        if onBreak { return Int(breakElapsed) } // a break counts up until you end it
        switch mode {
        case .idle, .done: return 0
        case .up: return Int(elapsed)
        case .down: return Int(ceil(max(0, Double(presetMin * 60) - elapsed)))
        }
    }

    var label: String {
        if let t = toast, now < toastUntil { return t }
        // From one hour on, the time in words, so "05:34" can't be read as minutes and seconds.
        let s = shownSeconds
        let withTime = { (key: String) in s >= 3600 ? L("label.withTime", L(key), Self.format(Double(s))) : L(key) }
        if onBreak { return withTime("label.onBreak") }
        switch mode {
        case .idle: return L("label.tapToStart")
        case .done: return L("label.done")
        case .up: return withTime(running ? "label.countingUp" : "label.paused")
        case .down: return running ? L("label.focus", presetMin) : withTime("label.paused")
        }
    }

    /// What the two digit pairs mean: minutes and seconds under an hour, hours and minutes from one hour on.
    var units: [String] {
        mode == .done && !onBreak || shownSeconds < 3600
            ? [L("unit.min"), L("unit.sec")] : [L("unit.hr"), L("unit.min"), L("unit.sec")]
    }

    /// Four digits (nil = unlit) and whether the colon is lit.
    /// Digit groups (nil = unlit) and whether the colons are lit. Seconds always show:
    /// MM:SS under an hour, H:MM:SS up to 9:59:59, HH:MM:SS from ten hours.
    var face: (groups: [[Int?]], colon: Bool) {
        if mode == .done && !onBreak {
            let on = Int(now.timeIntervalSinceReferenceDate * 2) % 2 == 0
            return (on ? [[0, 0], [0, 0]] : [[nil, nil], [nil, nil]], on)
        }
        let s = shownSeconds
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        let ticking = onBreak ? breakElapsed : elapsed
        let colon = !(running || onBreak) || ticking.truncatingRemainder(dividingBy: 1) < 0.5
        let mm: [Int?] = [m / 10, m % 10], ss: [Int?] = [sec / 10, sec % 10]
        if h == 0 { return ([[s / 60 / 10, s / 60 % 10], ss], colon) }
        return (h < 10 ? [[h], mm, ss] : [[h / 10, h % 10], mm, ss], colon)
    }

    // MARK: Today

    var workedToday: TimeInterval {
        log.filter { $0.kind == .work }.reduce(0) { $0 + $1.duration } + (segmentStart.map { now.timeIntervalSince($0) } ?? 0)
    }
    var breaksToday: Int { log.filter { $0.kind == .rest }.count + (onBreak ? 1 : 0) }
    var breakTimeToday: TimeInterval {
        log.filter { $0.kind == .rest }.reduce(0) { $0 + $1.duration } + (onBreak ? breakElapsed : 0)
    }

    var summary: String {
        let b = breaksToday
        return b == 1 ? L("summary.one", Self.format(workedToday)) : L("summary", Self.format(workedToday), b)
    }

    static func format(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return m < 60 ? L("duration.m", m) : L("duration.hm", m / 60, m % 60)
    }

    func clearLog() {
        log = []
        if segmentStart != nil { segmentStart = Self.clock() }
        save()
    }

    // MARK: Actions

    func tapScreen() {
        debugLog("tapScreen mode=\(mode) onBreak=\(onBreak)")
        if awaySince != nil { comeBack(countAsBreak: false); return }
        if onBreak {
            endBreak()
            play("back", 0.8)
            return
        }
        switch mode {
        case .idle: start(.up, minutes: 0); play("start", 0.8)
        case .done: reset(); click()
        case .up, .down:
            if running { pause(); click() } else { resume(); play("start", 0.8) }
        }
    }

    func startPreset(_ minutes: Int) {
        debugLog("preset \(minutes)")
        if onBreak { endBreak(resumeWork: false) }
        start(.down, minutes: minutes)
        play("start", 0.8)
    }

    /// Break button: starts a break, or ends it and goes back to work.
    func toggleBreak() {
        debugLog("break toggle onBreak=\(onBreak)")
        if onBreak {
            endBreak()
            play("back", 0.8)
        } else {
            beginBreak()
            play("break", 0.8)
        }
    }

    func reset() {
        awaySince = nil
        if onBreak { endBreak(resumeWork: false) }
        closeSegment()
        stopAlarm()
        mode = .idle
        running = false
        banked = 0
        startedAt = nil
        presetMin = 0
        now = Self.clock()
        changed()
    }

    func cycleVolume() { volume = (volume + 1) % 3; click() }
    func cycleBrightness() { brightness = (brightness + 1) % 3; click() }

    private func start(_ m: Mode, minutes: Int) {
        closeSegment()
        stopAlarm()
        mode = m
        presetMin = minutes
        banked = 0
        startedAt = Self.clock()
        now = Self.clock()
        running = true
        segmentStart = now
        cheered = []
        toast = nil
        awaySince = nil
        changed()
    }

    private func pause() {
        now = Self.clock()
        banked = elapsed
        startedAt = nil
        running = false
        closeSegment()
        changed()
    }

    private func resume() {
        startedAt = Self.clock()
        now = Self.clock()
        running = true
        segmentStart = now
        markPassedMilestones()
        changed()
    }

    private func beginBreak() {
        awaySince = nil
        resumeAfterBreak = running
        if running { pause() }
        if mode == .done { mode = .idle; presetMin = 0 }
        stopAlarm()
        now = Self.clock()
        onBreak = true
        breakStartedAt = now
        changed()
    }

    private func endBreak(resumeWork: Bool = true) {
        now = Self.clock()
        if let s = breakStartedAt { record(.rest, from: s, to: now) }
        onBreak = false
        breakStartedAt = nil
        stopAlarm()
        if resumeWork && resumeAfterBreak && (mode == .up || mode == .down) { resume() }
        resumeAfterBreak = false
        changed()
    }

    private func tick() {
        now = Self.clock()
        rollDayIfNeeded()
        if running && !onBreak && now.timeIntervalSince(lastIdleCheck) >= 5 {
            lastIdleCheck = now
            let idle = Self.idleSeconds()
            if idle >= Self.idleLimit { away(at: now.addingTimeInterval(-idle)); return }
        }
        if mode == .down && running && elapsed >= Double(presetMin * 60) { finish() }
        if running { checkMilestones() }
        if toast != nil && now >= toastUntil { toast = nil }
        if now.timeIntervalSince(lastSave) > 30 { save() }
    }

    /// The milestones the current state has reached, keyed so each fires once.
    private func reachedMilestones() -> [(key: String, text: String, day: Bool)] {
        var out: [(String, String, Bool)] = []
        if mode == .up {
            let quarters = Int(elapsed / 900)
            if quarters >= 1 { out.append(("up\(quarters)", L("cheer.quarter", quarters * 15), false)) }
        }
        if mode == .down {
            let total = Double(presetMin * 60)
            if total >= 600 && elapsed >= total / 2 { out.append(("half", L("cheer.half"), false)) }
            if total >= 300 && total - elapsed <= 60 { out.append(("last", L("cheer.last"), false)) }
        }
        let hours = Int(workedToday / 3600)
        if hours >= 1 { out.append(("day\(hours)", L("cheer.day", hours), true)) }
        return out
    }

    private func checkMilestones() {
        if toast != nil && now < toastUntil { return }
        for m in reachedMilestones() {
            if m.day ? dayCheered.contains(m.key) : cheered.contains(m.key) { continue }
            if m.day { dayCheered.insert(m.key) } else { cheered.insert(m.key) }
            toast = m.text
            toastUntil = now.addingTimeInterval(4)
            play("milestone", 0.9)
            return // one cheer at a time; any other waits for its turn
        }
    }

    // MARK: Days and being away

    /// A new day: running stretches close at 23:59:59 and carry on from midnight; today's log starts empty.
    /// The history file and Notion keep everything.
    private func rollDayIfNeeded() {
        let today = Self.today
        guard today != day else { return }
        let midnight = Calendar.current.startOfDay(for: Self.clock())
        let lastSecond = midnight.addingTimeInterval(-1)
        if let s = segmentStart, s < midnight { record(.work, from: s, to: lastSecond); segmentStart = midnight }
        if onBreak, let b = breakStartedAt, b < midnight { record(.rest, from: b, to: lastSecond); breakStartedAt = midnight }
        log = []
        dayCheered = []
        day = today
        debugLog("new day \(today)")
        save()
    }

    /// Called from the app's 1-second timer, so the day also rolls over while nothing is running.
    func housekeeping() {
        if awaySince != nil { now = Self.clock() }
        if !running && !onBreak { rollDayIfNeeded() }
    }

    /// The Mac slept or locked, or nothing was touched for 15 minutes: running work ends at `t` (the last input)
    /// and pauses. Away time never counts as work. A running break just keeps going.
    func away(at t: Date) {
        guard running, !onBreak, awaySince == nil else { return }
        let at = max(t, segmentStart ?? t)
        banked += startedAt.map { at.timeIntervalSince($0) } ?? 0
        startedAt = nil
        running = false
        if let s = segmentStart { record(.work, from: s, to: at) }
        segmentStart = nil
        awaySince = at
        now = Self.clock()
        debugLog("away since \(at)")
        changed()
    }

    /// Back from being away: carry on with the work timer, optionally logging the away time as a break.
    func comeBack(countAsBreak: Bool) {
        guard let a = awaySince else { return }
        now = Self.clock()
        if countAsBreak { record(.rest, from: a, to: now) }
        awaySince = nil
        if mode == .up || mode == .down { resume() } else { changed() }
        play("back", 0.8)
    }

    var awayText: String {
        guard let a = awaySince else { return "" }
        let m = max(0, Int(now.timeIntervalSince(a)) / 60)
        return L("away.text", Self.format(Double(m * 60)).lowercased(), a.formatted(date: .omitted, time: .shortened))
    }

    /// Self-test only: runs one tick on the fake clock.
    func debugTick() {
        guard Self.preview else { return }
        tick()
    }

    /// Self-test only: pretends `seconds` more have passed in the running session, then ticks.
    func debugSkip(_ seconds: TimeInterval, cheer: Bool = true) {
        guard Self.preview else { return }
        startedAt = startedAt?.addingTimeInterval(-seconds)
        segmentStart = segmentStart?.addingTimeInterval(-seconds)
        if !cheer { markPassedMilestones() }
        tick()
    }

    /// Counts milestones already behind us as cheered, so resuming or reopening doesn't replay them.
    private func markPassedMilestones() {
        for m in reachedMilestones() {
            if m.day { dayCheered.insert(m.key) } else { cheered.insert(m.key) }
        }
    }

    private func finish() {
        closeSegment()
        banked = 0
        startedAt = nil
        running = false
        mode = .done
        ring()
        changed()
    }

    private func ring() {
        stopAlarm()
        var plays = 0
        alarm = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] t in
            self?.play("done", 1.0)
            plays += 1
            if plays >= 3 { t.invalidate() }
        }
        alarm?.fire()
    }

    private func closeSegment() {
        if let s = segmentStart { record(.work, from: s, to: Self.clock()) }
        segmentStart = nil
    }

    private func record(_ kind: LogEntry.Kind, from start: Date, to end: Date) {
        guard end.timeIntervalSince(start) >= 5 else { return } // ignore accidental taps
        let entry = LogEntry(kind: kind, start: start, end: end)
        log.append(entry)
        Self.onRecord?(entry)
        if !Self.preview {
            WorkHistory.append([entry])
            NotionSync.shared.enqueue(entry)
        }
    }

    /// Ticks only while something is moving or flashing.
    private func updateTicker() {
        let needed = running || onBreak || mode == .done
        if needed && ticker == nil {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        } else if !needed {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func changed() {
        updateTicker()
        save()
    }

    private func stopAlarm() { alarm?.invalidate(); alarm = nil }

    // MARK: Saving

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Self.clock())
    }

    func save() {
        guard !Self.preview else { return }
        now = Self.clock()
        lastSave = now
        // A running work stretch is saved as finished up to now, so nothing is lost if the Mac shuts down.
        var entries = log
        if let s = segmentStart, now.timeIntervalSince(s) >= 5 { entries.append(LogEntry(kind: .work, start: s, end: now)) }
        let state = SavedState(day: Self.today, mode: mode.rawValue, presetMin: presetMin, elapsed: elapsed,
                               onBreak: onBreak, breakStartedAt: breakStartedAt,
                               resumeAfterBreak: resumeAfterBreak || running, log: entries,
                               runningAt: running ? now : nil)
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: Self.stateKey) }
    }

    /// Comes back paused where it was. A break that was running keeps its start time.
    private func restore() {
        guard !Self.preview, let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let s = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        // Copy the saved log into the permanent history first (skips entries already there),
        // so a day's work survives the daily reset below.
        WorkHistory.append(s.log)
        day = s.day
        log = s.log
        mode = Mode(rawValue: s.mode) ?? .idle
        if mode == .done { mode = .idle }
        presetMin = mode == .idle ? 0 : s.presetMin
        banked = mode == .idle ? 0 : s.elapsed
        onBreak = s.onBreak
        breakStartedAt = s.breakStartedAt
        resumeAfterBreak = s.onBreak && s.resumeAfterBreak
        now = Self.clock()
        // A quick restart (like an update) while working: carry on counting from where it stopped.
        if let r = s.runningAt, !onBreak, mode == .up || mode == .down, now.timeIntervalSince(r) < 120, s.day == Self.today {
            startedAt = r
            segmentStart = r
            running = true
        }
    }

    // MARK: Sound

    private func click() { play("Tink", 0.5) }

    private func play(_ name: String, _ gain: Float) {
        guard volume > 0, !Self.preview, let s = NSSound(named: name)?.copy() as? NSSound else { return }
        s.volume = gain * [0, 0.3, 1.0][volume]
        s.play()
    }
}

// MARK: - Seven-segment LED digits

enum SevenSeg {
    // Segments: 0 top, 1 top-right, 2 bottom-right, 3 bottom, 4 bottom-left, 5 top-left, 6 middle
    static let map: [Set<Int>] = [
        [0, 1, 2, 3, 4, 5], [1, 2], [0, 1, 6, 4, 3], [0, 1, 6, 2, 3], [5, 6, 1, 2],
        [0, 5, 6, 2, 3], [0, 5, 6, 4, 3, 2], [0, 1, 2], [0, 1, 2, 3, 4, 5, 6], [0, 1, 2, 3, 5, 6],
    ]

    static let slant: CGFloat = 0.09

    static func paths(in size: CGSize) -> [Path] {
        let w = size.width - size.height * slant, h = size.height
        let t = w * 0.2, g = t * 0.18
        let l = t / 2, r = w - t / 2, top = t / 2, mid = h / 2, bot = h - t / 2
        let skew = CGAffineTransform(a: 1, b: 0, c: -slant, d: 1, tx: h * slant, ty: 0)
        return [
            hseg(l + g, r - g, top, t), vseg(r, top + g, mid - g, t), vseg(r, mid + g, bot - g, t),
            hseg(l + g, r - g, bot, t), vseg(l, mid + g, bot - g, t), vseg(l, top + g, mid - g, t),
            hseg(l + g, r - g, mid, t),
        ].map { $0.applying(skew) }
    }

    private static func hseg(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat, _ t: CGFloat) -> Path {
        let k = t / 2
        return Path { p in
            p.addLines([.init(x: x0, y: y), .init(x: x0 + k, y: y - k), .init(x: x1 - k, y: y - k),
                        .init(x: x1, y: y), .init(x: x1 - k, y: y + k), .init(x: x0 + k, y: y + k)])
            p.closeSubpath()
        }
    }

    private static func vseg(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat, _ t: CGFloat) -> Path {
        let k = t / 2
        return Path { p in
            p.addLines([.init(x: x, y: y0), .init(x: x + k, y: y0 + k), .init(x: x + k, y: y1 - k),
                        .init(x: x, y: y1), .init(x: x - k, y: y1 - k), .init(x: x - k, y: y0 + k)])
            p.closeSubpath()
        }
    }
}

struct LEDDigit: View {
    let digit: Int?
    let color: Color
    let level: Double
    var width: CGFloat = 30
    var height: CGFloat = 50

    var body: some View {
        Canvas { ctx, size in
            let lit = digit.map { SevenSeg.map[$0] } ?? []
            let paths = SevenSeg.paths(in: size)
            for (i, p) in paths.enumerated() where !lit.contains(i) {
                ctx.fill(p, with: .color(color.opacity(0.07)))
            }
            var glow = ctx
            glow.addFilter(.shadow(color: color.opacity(0.85 * level), radius: 5))
            for (i, p) in paths.enumerated() where lit.contains(i) {
                glow.fill(p, with: .color(color.opacity(level)))
            }
        }
        .frame(width: width, height: height)
    }
}

struct LEDColon: View {
    let on: Bool
    let color: Color
    let level: Double
    var width: CGFloat = 10
    var height: CGFloat = 50

    var body: some View {
        Canvas { ctx, size in
            var glow = ctx
            if on { glow.addFilter(.shadow(color: color.opacity(0.85 * level), radius: 4)) }
            let r = size.height * 0.055
            for y in [size.height * 0.34, size.height * 0.66] {
                let x = size.width / 2 - (y - size.height / 2) * SevenSeg.slant
                let dot = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                glow.fill(dot, with: .color(on ? color.opacity(level) : color.opacity(0.07)))
            }
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Views

func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

extension TimerModel {
    /// Turquoise while work is running, coral when paused or stopped, sand on a break.
    var ledColor: Color { onBreak ? .sand : (mode == .done ? .offWhite : (running ? .turquoise : .coral)) }
}

struct LEDDigits: View {
    @ObservedObject var m: TimerModel

    /// The digit row at most this wide (the 4-digit face is 146) and this tall; more digits get narrower.
    static let maxWidth: CGFloat = 176
    static let maxHeight: CGFloat = 50
    static let gap: CGFloat = 4

    var body: some View {
        let face = m.face
        let c = m.ledColor
        let units = m.units
        let n = CGFloat(face.groups.joined().count), g = CGFloat(face.groups.count)
        let colonW: CGFloat = 10
        // n digits, gaps inside groups, and a colon with a gap each side between groups.
        let fixed = (n - g) * Self.gap + (g - 1) * (colonW + 2 * Self.gap)
        let w = min(30, (Self.maxWidth - fixed) / n)
        let h = min(Self.maxHeight, w / 0.6)
        let groupWidth = { (count: Int) in CGFloat(count) * w + CGFloat(count - 1) * Self.gap }
        VStack(spacing: 3) {
            HStack(spacing: Self.gap) {
                ForEach(Array(face.groups.enumerated()), id: \.offset) { k, group in
                    if k > 0 { LEDColon(on: face.colon, color: c, level: m.level, width: colonW, height: h) }
                    ForEach(Array(group.enumerated()), id: \.offset) { _, d in
                        LEDDigit(digit: d, color: c, level: m.level, width: w, height: h)
                    }
                }
            }
            .frame(height: Self.maxHeight) // same row height for every length, so nothing below moves
            // A caption centred under each group of digits.
            HStack(spacing: colonW + 2 * Self.gap) {
                ForEach(Array(face.groups.enumerated()), id: \.offset) { k, group in
                    Text(units[min(k, units.count - 1)]).frame(width: groupWidth(group.count))
                }
            }
            .font(mono(7))
            .tracking(letterSpacing(0.8))
            .foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// The outer ring: 60 minute ticks plus a glowing arc that shows progress.
struct ProgressRing: View {
    @ObservedObject var m: TimerModel

    var body: some View {
        let c = m.ledColor
        let flashOn = m.mode != .done || m.face.colon
        ZStack {
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let rOut = size.width / 2, rIn = rOut - 5
                for i in 0..<60 {
                    let a = Double(i) / 60 * 2 * .pi - .pi / 2
                    let len: CGFloat = i % 5 == 0 ? 5 : 2.5
                    var p = Path()
                    p.move(to: CGPoint(x: center.x + cos(a) * rOut, y: center.y + sin(a) * rOut))
                    p.addLine(to: CGPoint(x: center.x + cos(a) * (rOut - len), y: center.y + sin(a) * (rOut - len)))
                    ctx.stroke(p, with: .color(.white.opacity(i % 5 == 0 ? 0.28 : 0.12)), lineWidth: 1)
                }
                _ = rIn
            }
            Circle()
                .inset(by: 13)
                .stroke(.white.opacity(0.06), lineWidth: 5)
            Circle()
                .inset(by: 13)
                .trim(from: 0, to: flashOn ? m.progress : 0)
                .stroke(c.opacity(m.level), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: c.opacity(0.8 * m.level), radius: 6)
        }
        .allowsHitTesting(false)
    }
}

struct Dot: View {
    let text: String
    var active = false
    var tint: Color = .coral
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(raleway(.bold, 12))
                .foregroundStyle(active ? .white : .white.opacity(hover ? 0.95 : 0.72))
                .frame(width: 34, height: 34)
                .background(
                    Circle().fill(active ? tint : .white.opacity(hover ? 0.11 : 0.06))
                        .shadow(color: active ? tint.opacity(0.6) : .clear, radius: 6)
                )
                .overlay(Circle().stroke(.white.opacity(active ? 0 : 0.08), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SmallIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 0.95 : 0.5))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct BreakButton: View {
    @ObservedObject var m: TimerModel
    @State private var hover = false

    var body: some View {
        let active = m.onBreak
        Button(action: { m.toggleBreak() }) {
            HStack(spacing: 5) {
                Image(systemName: active ? "arrow.uturn.backward" : "cup.and.saucer.fill").font(.system(size: 10, weight: .semibold))
                Text(L(active ? "button.backToWork" : "button.break")).font(raleway(.bold, 12))
            }
            .foregroundStyle(active ? Color.black : .white.opacity(hover ? 0.95 : 0.8))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(active ? Color.sand : .white.opacity(hover ? 0.11 : 0.06)))
            .overlay(Capsule().stroke(.white.opacity(active ? 0 : 0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L(active ? "help.endBreak" : "help.takeBreak"))
    }
}

/// Shown on the dial after you were away: work paused, you choose what that time was.
struct AwayPrompt: View {
    @ObservedObject var m: TimerModel

    var body: some View {
        VStack(spacing: 12) {
            Text(L("away.welcome")).font(mono(8.5)).tracking(letterSpacing(1.1)).foregroundStyle(.white.opacity(0.55))
            Text(m.awayText)
                .font(raleway(.semibold, 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.offWhite)
                .frame(width: 210)
            VStack(spacing: 8) {
                choice(L("away.resume"), fill: .turquoise) { m.comeBack(countAsBreak: false) }
                choice(L("away.asBreak"), fill: .sand) { m.comeBack(countAsBreak: true) }
            }
            .padding(.top, 4)
        }
        .frame(width: TimerView.diameter, height: TimerView.diameter)
        .background(Circle().fill(Color.black.opacity(0.94)))
    }

    private func choice(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(raleway(.bold, 12)).foregroundStyle(.black)
                .frame(width: 160, height: 30)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct TimerView: View {
    @ObservedObject var m: TimerModel
    @State private var hover = false
    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    @AppStorage("onTop") private var onTop = true
    @ObservedObject private var sync = NotionSync.shared
    @ObservedObject private var loc = Loc.shared
    @AppStorage("scale") private var storedScale = 1.0
    @State private var resizing = false
    @State private var pinchStart: Double?

    static let sizes: [(name: String, scale: Double)] = [("size.small", 0.65), ("size.medium", 1.0), ("size.large", 1.4)]
    static let scaleRange = 0.55...1.8
    private var scale: CGFloat { CGFloat(min(max(storedScale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)) }

    private func setScale(_ v: Double) {
        storedScale = min(max(v, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    }

    /// Drag the corner handle: the window grows or shrinks from its top-left corner.
    private var resizeHandle: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                // Only a press that starts on the handle itself resizes.
                guard let panel = timerPanel, resizing || CGRect(x: 0, y: 0, width: 24, height: 24).contains(v.startLocation) else { return }
                resizing = true
                let mouse = NSEvent.mouseLocation, f = panel.frame
                let side = max(mouse.x - f.minX, f.maxY - mouse.y)
                setScale(Double(side / Self.windowSide))
                let s = Self.windowSide * scale
                panel.setFrame(NSRect(x: f.minX, y: f.maxY - s, width: s, height: s), display: true)
            }
            .onEnded { _ in resizing = false; timerPanel?.invalidateShadow() }
    }

    /// Trackpad pinch on the dial.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchStart == nil { pinchStart = Double(scale) }
                setScale((pinchStart ?? 1) * v.magnification)
            }
            .onEnded { _ in pinchStart = nil }
    }
    /// The window's side length at scale 1: the dial plus room for its shadow.
    static let windowSide: CGFloat = diameter + 20

    static let diameter: CGFloat = 300

    private func languageButton(_ code: String, _ name: String) -> some View {
        let mark = loc.choice == code ? "✓ " : ""
        return Button(mark + name) { loc.choice = code }
    }

    /// Moves the window by dragging the body. Uses screen coordinates so moving the window doesn't feed back into the drag.
    private var moveWindow: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in
                guard let panel = timerPanel else { return }
                let mouse = NSEvent.mouseLocation
                if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
                guard let start = dragStart else { return }
                panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                             y: start.origin.y + mouse.y - start.mouse.y))
            }
            .onEnded { _ in dragStart = nil }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.bodyTop, Color.bodyBottom], center: .top,
                                     startRadius: 0, endRadius: Self.diameter))
                .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
                .gesture(moveWindow)

            ProgressRing(m: m)

            VStack(spacing: 0) {
                if let logo = brandLogo {
                    Image(nsImage: logo).resizable().interpolation(.high).scaledToFit().frame(height: 24)
                }
                Text(m.label)
                    .font(mono(8.5))
                    .tracking(letterSpacing(1.1))
                    .foregroundStyle(m.mode == .done ? Color.offWhite : .white.opacity(0.55))
                    .padding(.top, 6)

                LEDDigits(m: m)
                    .padding(.top, 8)
                    .padding(.bottom, 5)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { m.tapScreen() }
                    .help(L("help.tap"))
                    .padding(.top, 2)

                Text(m.summary)
                    .font(mono(7.5))
                    .tracking(letterSpacing(0.8))
                    .foregroundStyle(.white.opacity(0.42))

                HStack(spacing: 6) {
                    ForEach([10, 20, 40, 60], id: \.self) { min in
                        Dot(text: "\(min)", active: m.mode == .down && m.presetMin == min, tint: m.running ? .turquoise : .coral) { m.startPreset(min) }
                    }
                }
                .padding(.top, 6)

                HStack(spacing: 2) {
                    SmallIcon(symbol: ["sun.min", "sun.max", "sun.max.fill"][m.brightness], help: L("help.brightness")) { m.cycleBrightness() }
                    SmallIcon(symbol: "arrow.counterclockwise", help: L("help.reset")) { m.reset() }
                    BreakButton(m: m).padding(.horizontal, 4)
                    SmallIcon(symbol: ["speaker.slash", "speaker.wave.1", "speaker.wave.3"][m.volume], help: L("help.volume")) { m.cycleVolume() }
                    SmallIcon(symbol: "xmark", help: L("help.hide")) { toggleTimerPanel() }
                        .opacity(hover ? 1 : 0.35)
                }
                .padding(.top, 10)
            }
            .padding(.top, 6)
        }
        .overlay { if m.awaySince != nil { AwayPrompt(m: m) } }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .padding(10) // room for the window shadow
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color(white: 0.16)))
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                .contentShape(Circle())
                .gesture(resizeHandle)
                .help(L("help.resize"))
                .opacity(hover || resizing ? 1 : 0)
                .padding(16)
        }
        .gesture(pinch)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: Self.windowSide * scale, height: Self.windowSide * scale, alignment: .topLeading)
        .onHover { hover = $0 }
        .onChange(of: storedScale) { if !resizing { resizeTimerPanel(side: Self.windowSide * scale) } }
        .contextMenu {
            Menu(L("menu.size")) {
                ForEach(Self.sizes.indices, id: \.self) { i in
                    Button((abs(storedScale - Self.sizes[i].scale) < 0.01 ? "✓ " : "") + L(Self.sizes[i].name)) {
                        setScale(Self.sizes[i].scale)
                    }
                }
                Divider()
                Text(L("menu.sizeHint"))
            }
            Button((onTop ? "✓ " : "") + L("menu.stayOnTop")) {
                onTop.toggle()
                timerPanel?.level = onTop ? .floating : .normal
            }
            Button((SMAppService.mainApp.status == .enabled ? "✓ " : "") + L("menu.openAtLogin")) {
                let svc = SMAppService.mainApp
                try? svc.status == .enabled ? svc.unregister() : svc.register()
            }
            Divider()
            Menu(L("menu.today", TimerModel.format(m.workedToday).lowercased())) {
                Text(L("menu.worked", TimerModel.format(m.workedToday).lowercased()))
                Text(m.breaksToday == 1 ? L("menu.breaks.one", TimerModel.format(m.breakTimeToday).lowercased())
                                        : L("menu.breaks", m.breaksToday, TimerModel.format(m.breakTimeToday).lowercased()))
                Divider()
                ForEach(m.log.reversed()) { e in
                    Text("\(clock(e.start)) – \(clock(e.end))   \(L(e.kind == .work ? "kind.work" : "kind.break"))   \(TimerModel.format(e.duration).lowercased())")
                }
                if !m.log.isEmpty {
                    Divider()
                    Button(L("menu.clearLog")) { m.clearLog() }
                }
            }
            Button(L(m.onBreak ? "menu.backToWork" : "menu.takeBreak")) { m.toggleBreak() }
            Button(L("menu.resetTimer")) { m.reset() }
            Divider()
            Text(sync.statusText)
            Button(L(sync.connected ? "menu.notionSettings" : "menu.connectNotion")) { ConnectNotionWindow.show() }
            Divider()
            Menu(L("menu.language")) {
                languageButton("system", L("lang.system"))
                languageButton("en", "English")
                languageButton("ar", "العربية")
            }
            Divider()
            Button(L("menu.hide") + "   ⌃⌥T") { toggleTimerPanel() }
            Button(L("menu.quit")) { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Floating window

weak var timerPanel: NSPanel?

/// Loaded once; the view redraws ten times a second.
let brandLogo = Bundle.main.image(forResource: "logo")

/// Shows the floating timer if hidden, hides it if showing.
func toggleTimerPanel() {
    guard let panel = timerPanel else { return }
    panel.isVisible ? panel.orderOut(nil) : showTimerPanel()
}

/// Brings the timer forward, moving it onto the main screen if its saved spot is off every screen.
func showTimerPanel() {
    guard let panel = timerPanel else { return }
    let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame.insetBy(dx: 40, dy: 40)) }
    if !onScreen, let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
        panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.maxY - panel.frame.height - 24))
    }
    panel.orderFrontRegardless()
}

/// ⌃⌥T anywhere shows or hides the timer. Carbon hot keys need no Accessibility permission.
func registerShowHideHotKey() {
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x484E_5449), id: 1) // "HNTI"
    RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { toggleTimerPanel() }
        return noErr
    }, 1, &spec, nil, nil)
}

/// Resizes the floating window around its center, kept on screen.
func resizeTimerPanel(side: CGFloat) {
    guard let panel = timerPanel else { return }
    let old = panel.frame
    var f = NSRect(x: old.midX - side / 2, y: old.midY - side / 2, width: side, height: side)
    if let screen = (panel.screen ?? NSScreen.main)?.visibleFrame {
        f.origin.x = min(max(f.minX, screen.minX), screen.maxX - side)
        f.origin.y = min(max(f.minY, screen.minY), screen.maxY - side)
    }
    panel.setFrame(f, display: true, animate: true)
    panel.invalidateShadow()
}

/// Where the self-test clicks, in window points from the top-left.
enum SelfTest {
    static let screen = CGPoint(x: 160, y: 140)
    static let ten = CGPoint(x: 100, y: 214)
    static let breakButton = CGPoint(x: 160, y: 252)
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ClickThroughHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = TimerModel()
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = ClickThroughHostingView(rootView: TimerView(m: model))
        let size = host.fittingSize

        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let onTop = UserDefaults.standard.object(forKey: "onTop") as? Bool ?? true
        panel.level = onTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if !panel.setFrameUsingName("hanadiTimer"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24))
        }
        // A saved frame from an older layout may have a different size; keep its top-left corner, use the current size.
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.setFrameAutosaveName("hanadiTimer")
        panel.orderFrontRegardless()
        timerPanel = panel
        setUpMenuBar()
        watchForAway()
        registerShowHideHotKey()
        installEditMenu()
        if !TimerModel.preview {
            // After the timer is showing: reading the key may ask for Keychain permission.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NotionKeychain.loadInBackground { NotionSync.shared.start() }
            }
        }
        debugLog("launched: mode=\(model.mode) running=\(model.running) work=\(Int(model.elapsed))s worked=\(Int(model.workedToday))s breaks=\(model.breaksToday)")
        if CommandLine.arguments.contains("--selftest") { selfTest() }
        if CommandLine.arguments.contains("--menutest") { menuTest() }
        if CommandLine.arguments.contains("--featuretest") { featureTest() }
        if let i = CommandLine.arguments.firstIndex(of: "--connectshot"), i + 1 < CommandLine.arguments.count {
            ConnectNotionWindow.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let v = ConnectNotionWindow.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                }
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--quit") { NSApp.terminate(nil) }
    }

    /// Checks sounds load (without playing), milestone cheers, hide/show and the menu bar item.
    private func featureTest() {
        for name in ["start", "back", "break", "milestone", "done", "Tink"] {
            debugLog("sound \(name): \(NSSound(named: name) != nil ? "loads" : "MISSING")")
        }
        let m = TimerModel()
        m.startPreset(10)
        m.debugSkip(301); debugLog("10m at 5:01 → \(m.label)")
        m.debugSkip(5); debugLog("4s later → \(m.label)")
        m.debugSkip(240); debugLog("10m at 9:06 → \(m.label)")
        m.reset(); m.tapScreen()
        m.debugSkip(901); debugLog("count-up at 15:01 → \(m.label)")
        m.debugSkip(2700); debugLog("count-up at 1:00:01 → \(m.label)")
        m.tapScreen(); m.tapScreen(); debugLog("pause + resume at 1:00 → \(m.label) (no repeat cheer expected)")

        model.tapScreen()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        debugLog("after simulated sleep: running=\(model.running) awayPrompt=\(model.awaySince != nil)")
        model.reset()
        panel.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        panel.orderOut(nil)
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        debugLog("reopen from off-screen: visible=\(panel.isVisible) onScreen=\(NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) })")
        toggleTimerPanel(); debugLog("after hide: visible=\(panel.isVisible)")
        toggleTimerPanel(); debugLog("after show: visible=\(panel.isVisible)")
        model.tapScreen(); updateStatusItem()
        debugLog("menu bar while running: title='\(statusItem.button?.title ?? "nil")' image=\(statusItem.button?.image != nil)")
        let menu = statusItem.menu!
        menuNeedsUpdate(menu)
        debugLog("menu bar menu: \(menu.items.map { $0.isSeparatorItem ? "—" : $0.title })")
        model.reset(); updateStatusItem()
        debugLog("menu bar idle: title='\(statusItem.button?.title ?? "nil")'")
        NSApp.terminate(nil)
    }

    /// Right-clicks the dial, picks Size > Large from the real context menu, then Size > Medium.
    private func menuTest() {
        var picks = ["Large", "Medium"]
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu, menu.supermenu == nil else { return }
            let titles = menu.items.map(\.title)
            debugLog("context menu items: \(titles)")
            let t = Timer(timeInterval: 0.3, repeats: false) { _ in
                guard let size = menu.items.first(where: { $0.title == "Size" })?.submenu,
                      let pick = picks.first,
                      let i = size.items.firstIndex(where: { $0.title.hasSuffix(pick) }) else { menu.cancelTracking(); return }
                picks.removeFirst()
                menu.cancelTracking()
                size.performActionForItem(at: i)
                debugLog("picked \(pick)")
            }
            RunLoop.main.add(t, forMode: .common)
        }
        func rightClick() {
            let p = NSPoint(x: 160, y: panel.frame.height - 60)
            let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            panel.sendEvent(e)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            debugLog("start window: \(self.panel.frame.size)")
            rightClick()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                debugLog("after Large: \(self.panel.frame.size)")
                rightClick()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    debugLog("after Medium: \(self.panel.frame.size)")
                    if let o = observer { NotificationCenter.default.removeObserver(o) }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Clicks the screen and the 10m button through the window, then reports the timer state.
    private func selfTest() {
        let h = panel.frame.height
        func capture(_ name: String) {
            guard let v = panel.contentView, let dir = ProcessInfo.processInfo.environment["TIMER_SHOTS"],
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("live-\(name).png"))
        }
        let k = h / TimerView.windowSide // test points are at Medium size
        func click(_ x: CGFloat, _ yFromTop: CGFloat, then: @escaping () -> Void) {
            let p = NSPoint(x: x * k, y: h - yFromTop * k)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                panel.sendEvent(e)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: then)
        }
        let m = model
        func state(_ step: String) {
            debugLog("\(step): mode=\(m.mode) running=\(m.running) onBreak=\(m.onBreak) work=\(Int(m.elapsed))s shown=\(m.shownSeconds) worked=\(Int(m.workedToday))s breaks=\(m.breaksToday) log=\(m.log.map { "\($0.kind.rawValue) \(Int($0.duration))s" })")
        }
        func wait(_ t: Double, _ then: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: then) }
        wait(1) {
            click(SelfTest.screen.x, SelfTest.screen.y) {
                wait(6) {
                    state("worked ~7s")
                    click(SelfTest.breakButton.x, SelfTest.breakButton.y) {
                        state("on break")
                        capture("on-break")
                        wait(5) {
                            click(SelfTest.breakButton.x, SelfTest.breakButton.y) {
                                state("back to work")
                                click(SelfTest.ten.x, SelfTest.ten.y) {
                                    state("started 10m")
                                    let d = UserDefaults.standard, saved = d.object(forKey: "scale")
                                    d.set(0.65, forKey: "scale")
                                    wait(1) {
                                        debugLog("small window: \(self.panel.frame.size)")
                                        d.set(1.4, forKey: "scale")
                                        wait(1) {
                                            debugLog("large window: \(self.panel.frame.size)")
                                            d.set(saved ?? 1.0, forKey: "scale")
                                            wait(1) {
                                                debugLog("medium window: \(self.panel.frame.size)")
                                                NSApp.terminate(nil)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { model.save() }

    // MARK: Menu bar

    private func setUpMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.model.housekeeping()
            self?.updateStatusItem()
        }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
    }

    /// Timer icon when idle; icon plus the live time while working or on a break.
    func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let active = model.running || model.onBreak
        button.image = NSImage(systemSymbolName: model.onBreak ? "cup.and.saucer.fill" : "timer",
                               accessibilityDescription: "Hanadi Timer")
        button.imagePosition = active ? .imageLeading : .imageOnly
        if active {
            let s = model.shownSeconds
            let text = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                                 : String(format: "%02d:%02d", s / 60, s % 60)
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            ])
        } else {
            button.title = ""
        }
    }

    /// Rebuilt each time it opens so the titles match the timer.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            menu.addItem(item)
        }
        add(L(panel.isVisible ? "menu.hide" : "menu.show"), #selector(menuToggleTimer), key: "t", mods: [.control, .option])
        menu.addItem(.separator())
        if !model.onBreak {
            let title: String
            switch model.mode {
            case .idle: title = L("menu.startUp")
            case .done: title = L("menu.reset")
            case .up, .down: title = L(model.running ? "menu.pause" : "menu.resume")
            }
            add(title, #selector(menuStartPause))
        }
        add(L(model.onBreak ? "menu.backToWork" : "menu.takeBreak"), #selector(menuBreak))
        menu.addItem(.separator())
        let b = model.breaksToday
        add(L("menu.todayBar", TimerModel.format(model.workedToday).lowercased(), b), nil)
        menu.addItem(.separator())
        add(NotionSync.shared.statusText, nil)
        add(L(NotionSync.shared.connected ? "menu.notionSettings" : "menu.connectNotion"), #selector(menuConnectNotion))
        menu.addItem(.separator())
        add(L("menu.quit"), #selector(menuQuit), key: "q")
    }

    @objc private func menuToggleTimer() { toggleTimerPanel() }
    @objc private func menuStartPause() { model.tapScreen(); updateStatusItem() }
    @objc private func menuBreak() { model.toggleBreak(); updateStatusItem() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuConnectNotion() { ConnectNotionWindow.show() }

    // Opening the app again (Spotlight, Finder, Dock) while it runs always shows the timer.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showTimerPanel()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) { showTimerPanel() }

    /// Sleep, screen sleep, lock, screen saver or switching user: running work pauses at the last input.
    private func watchForAway() {
        let goneAway: (Notification) -> Void = { [weak self] note in
            guard let self else { return }
            let idle = TimerModel.idleSeconds()
            debugLog("away signal: \(note.name.rawValue)")
            self.model.away(at: TimerModel.clock().addingTimeInterval(-min(idle, 24 * 3600)))
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main, using: goneAway)
        }
        let dist = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            dist.addObserver(forName: Notification.Name(name), object: nil, queue: .main, using: goneAway)
        }
    }
}

registerBrandFonts()
if let lang = ProcessInfo.processInfo.environment["TIMER_LANG"] { Loc.shared.override = lang }

// `hanadiTimer --synctest <port>` replays sample stretches against a fake Notion server on localhost, then exits.
if let i = CommandLine.arguments.firstIndex(of: "--synctest"), i + 1 < CommandLine.arguments.count {
    TimerModel.preview = true
    let suite = "hanadi.timer.synctest"
    UserDefaults().removePersistentDomain(forName: suite)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hanadi-synctest-\(getpid())")
    let sync = NotionSync(folder: folder, defaults: UserDefaults(suiteName: suite)!,
                          base: URL(string: "http://127.0.0.1:\(CommandLine.arguments[i + 1])/v1/")!, key: { "test-key" })
    let iso = ISO8601DateFormatter()
    func e(_ k: LogEntry.Kind, _ a: String, _ b: String) -> LogEntry {
        LogEntry(kind: k, start: iso.date(from: "2026-10-23T\(a)-04:00")!, end: iso.date(from: "2026-10-23T\(b)-04:00")!)
    }
    func settle(_ seconds: Double = 3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    // Setting up from a page link: the fake server says it's a page, so a Work log database gets created.
    sync.setUp(link: "https://www.notion.so/My-Hours-0123456789abcdef0123456789abcdef") { r in print("setup: \(r)") }
    settle()
    print("database: \(sync.databaseID ?? "none") · \(sync.statusText)")
    print("bad link: \(NotionSync.notionID(from: "https://example.com/hello") ?? "rejected")")
    // Sending starts when the Work log is set up; pretend that was 22:35 so the samples below count.
    UserDefaults(suiteName: suite)!.set(iso.date(from: "2026-10-23T22:35:00-04:00")!, forKey: "notionSince")
    for x in [e(.work, "22:00:00", "22:30:00"),   // before sending started: must be ignored
              e(.work, "22:37:29", "22:44:03"), e(.work, "22:44:06", "22:44:12"), e(.work, "22:44:16", "22:46:09"),
              e(.rest, "22:46:17", "22:46:24"), e(.work, "22:46:24", "22:57:14"),
              e(.rest, "23:00:00", "23:10:00"), e(.rest, "23:11:00", "23:15:00"), e(.work, "23:15:00", "23:40:00")] {
        sync.enqueue(x)
    }
    settle()
    print("status: \(sync.statusText)")
    // A server error keeps the stretch queued; the next try sends it once.
    sync.enqueue(e(.rest, "23:50:00", "23:58:00"))
    settle()
    print("status after error: \(sync.statusText)")
    sync.enqueue(e(.rest, "23:50:00", "23:58:00")) // duplicate: must not queue twice
    sync.flush()
    settle()
    print("status after retry: \(sync.statusText)")
    try? FileManager.default.removeItem(at: folder)
    UserDefaults().removePersistentDomain(forName: suite)
    exit(0)
}

// `hanadiTimer --awaytest` checks midnight rollover and away handling on a fake clock, then exits.
if CommandLine.arguments.contains("--awaytest") {
    TimerModel.preview = true
    let iso = ISO8601DateFormatter()
    var fake = iso.date(from: "2026-10-23T23:59:00-04:00")!
    var idle: TimeInterval = 0
    TimerModel.clock = { fake }
    TimerModel.idleSeconds = { idle }
    var recorded: [String] = []
    let f = DateFormatter(); f.dateFormat = "MMM d HH:mm:ss"
    TimerModel.onRecord = { recorded.append("\($0.kind.rawValue) \(f.string(from: $0.start)) → \(f.string(from: $0.end))") }
    func show(_ step: String, _ m: TimerModel) {
        print("\(step): running=\(m.running) onBreak=\(m.onBreak) work=\(Int(m.elapsed))s today=\(Int(m.workedToday))s breaksToday=\(m.breaksToday) log=\(m.log.count) recorded=\(recorded)")
        recorded = []
    }
    MainActor.assumeIsolated {
        // 1. Working across midnight.
        let m = TimerModel()
        m.tapScreen()
        fake = iso.date(from: "2026-10-24T00:00:05-04:00")!; m.debugTick()
        show("work crosses midnight", m)
        fake = iso.date(from: "2026-10-24T00:05:00-04:00")!; m.tapScreen()
        show("paused 00:05", m)

        // 2. On a break across midnight.
        fake = iso.date(from: "2026-10-24T23:50:00-04:00")!
        let b = TimerModel(); b.toggleBreak()
        fake = iso.date(from: "2026-10-25T00:10:00-04:00")!; b.debugTick()
        show("break crosses midnight", b)
        fake = iso.date(from: "2026-10-25T00:20:00-04:00")!; b.toggleBreak()
        show("back to work 00:20", b)

        // 3. Idle 16 min while working: ends at last input, away prompt, count as break.
        fake = iso.date(from: "2026-10-25T09:00:00-04:00")!
        let a = TimerModel(); a.tapScreen()
        fake = iso.date(from: "2026-10-25T09:20:00-04:00")!; idle = 16 * 60; a.debugTick()
        show("idle 16m at 9:20", a)
        print("   prompt: \(a.awayText.replacingOccurrences(of: "\n", with: " ")) label=\(a.awaySince != nil)")
        fake = iso.date(from: "2026-10-25T11:30:00-04:00")!; idle = 0; a.housekeeping()
        print("   prompt later: \(a.awayText.replacingOccurrences(of: "\n", with: " "))")
        a.comeBack(countAsBreak: true)
        show("count it as break", a)

        // 4. Idle while on a break: the break keeps running.
        let c = TimerModel(); c.tapScreen(); c.toggleBreak()
        fake = iso.date(from: "2026-10-25T12:30:00-04:00")!; idle = 60 * 60; c.debugTick(); c.away(at: fake)
        show("idle on break", c)

        // 5. Away then Resume (no break logged).
        idle = 0
        let r = TimerModel(); r.tapScreen()
        fake = iso.date(from: "2026-10-25T12:40:00-04:00")!; r.away(at: fake)
        fake = iso.date(from: "2026-10-25T14:00:00-04:00")!; r.comeBack(countAsBreak: false)
        show("away then resume", r)
    }
    exit(0)
}

// `hanadiTimer --login on|off|status` sets or reports Open at Login, then exits.
if let i = CommandLine.arguments.firstIndex(of: "--login") {
    let svc = SMAppService.mainApp
    let want = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "status"
    do {
        if want == "on" { try svc.register() }
        if want == "off" { try svc.unregister() }
    } catch {
        print("error: \(error.localizedDescription)")
    }
    print("Open at Login: \(svc.status == .enabled ? "on" : svc.status == .requiresApproval ? "needs approval in System Settings" : "off")")
    exit(0)
}

// `hanadiTimer --snapshot <dir>` renders preview images and exits (used for design checks).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let states: [(String, (TimerModel) -> Void)] = [
        ("idle", { _ in }), ("focus20", { $0.startPreset(20) }), ("paused20", { $0.startPreset(20); $0.tapScreen() }), ("large", { $0.startPreset(40) }),
        ("45-12", { $0.tapScreen(); $0.debugSkip(45 * 60 + 12, cheer: false) }),
        ("1-05-30", { $0.tapScreen(); $0.debugSkip(3600 + 5 * 60 + 30, cheer: false) }),
        ("6-49-12", { $0.tapScreen(); $0.debugSkip(6 * 3600 + 49 * 60 + 12, cheer: false); $0.tapScreen() }),
        ("12-03-44", { $0.tapScreen(); $0.debugSkip(12 * 3600 + 3 * 60 + 44, cheer: false) }),
        ("away", { $0.tapScreen(); $0.debugSkip(40 * 60, cheer: false); $0.away(at: TimerModel.clock().addingTimeInterval(-25 * 60)) }), ("countup", { $0.tapScreen() }), ("break", { $0.toggleBreak() }),
    ]
    for (name, setup) in states { MainActor.assumeIsolated {
        TimerModel.preview = true
        let m = TimerModel()
        setup(m)
        let savedSize = UserDefaults.standard.object(forKey: "scale")
        defer { UserDefaults.standard.set(savedSize, forKey: "scale") }
        // The long-running states are checked at every size; the rest at one.
        let sizes: [(String, Double)] = ["45-12", "1-05-30", "6-49-12", "12-03-44"].contains(name)
            ? [("-small", 0.65), ("-medium", 1.0), ("-large", 1.4)] : [("", name == "large" ? 1.4 : 1.0)]
        for (tag, scale) in sizes {
            UserDefaults.standard.set(scale, forKey: "scale")
            let r = ImageRenderer(content: TimerView(m: m).background(Color(white: 0.85)))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let lang = Loc.shared.override.map { "-\($0)" } ?? ""
                try? png.write(to: dir.appendingPathComponent("timer-\(name)\(tag)\(lang).png"))
            }
        }
    } }
    exit(0)
}

TimerModel.preview = (CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--menutest") || CommandLine.arguments.contains("--featuretest") || CommandLine.arguments.contains("--connectshot")) && ProcessInfo.processInfo.environment["TIMER_SAVE"] == nil

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
