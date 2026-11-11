// Arabic and English text. Follows the Mac's language unless a language is picked in the right-click menu.

import Foundation
import SwiftUI

final class Loc: ObservableObject {
    static let shared = Loc()

    /// "system", "en" or "ar".
    @Published var choice: String = UserDefaults.standard.string(forKey: "language") ?? "system" {
        didSet {
            UserDefaults.standard.set(choice, forKey: "language")
            bundle = Self.bundle(for: code)
        }
    }

    private var bundle: Bundle?

    private init() { bundle = Self.bundle(for: code) }

    /// Self-tests and snapshots pick a language without saving it.
    var override: String? { didSet { bundle = Self.bundle(for: code) } }

    /// The language in use: the picked one, or the Mac's first preferred language if it is Arabic.
    var code: String {
        if let override { return override }
        if choice == "en" || choice == "ar" { return choice }
        return Locale.preferredLanguages.first?.hasPrefix("ar") == true ? "ar" : "en"
    }

    var isArabic: Bool { code == "ar" }

    private static func bundle(for code: String) -> Bundle? {
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    func string(_ key: String) -> String {
        if let s = bundle?.localizedString(forKey: key, value: nil, table: nil), s != key { return s }
        // Fall back to English, then to the key itself.
        return Self.bundle(for: "en")?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}

/// The text for `key` in the current language, with `%d` / `%@` filled in from `args`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Loc.shared.string(key)
    return args.isEmpty ? format : String(format: format, locale: Locale(identifier: "en_US_POSIX"), arguments: args)
}

/// Letter spacing for the small capital labels; Arabic letters join, so they get none.
func letterSpacing(_ value: CGFloat) -> CGFloat { Loc.shared.isArabic ? 0 : value }
