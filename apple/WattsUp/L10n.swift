import Foundation

/// English and French. Strings are keyed by their English text: SwiftUI views look them up
/// by themselves in the app bundle, the rest of the code goes through `tr`.
enum L10n {
    /// Forces a language ("en", "fr"); tests use it, the app follows the system.
    static var forced: String?

    static var language: String {
        forced ?? resolve(preferred: Locale.preferredLanguages)
    }

    /// The first preferred language the app speaks, as SwiftUI and AppKit pick it, so that
    /// both halves of the interface agree: with German then French, both use French.
    static func resolve(preferred: [String]) -> String {
        Bundle.preferredLocalizations(from: ["en", "fr"], forPreferences: preferred).first ?? "en"
    }

    private static var tables: [String: [String: String]] = [:]
    private static let lock = NSLock()

    /// The strings of a language; nil when its file is missing.
    static func table(_ language: String) -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        if let table = tables[language] { return table }
        guard let url = url(language), let table = NSDictionary(contentsOf: url) as? [String: String] else { return nil }
        tables[language] = table
        return table
    }

    /// In the assembled app the files sit in Contents/Resources; under SwiftPM (tests,
    /// `swift run`) they are in the package's resource bundle, under the copied
    /// `Resources` folder. The bundle's own layout (flat, or with a Contents folder)
    /// depends on the SwiftPM version: `Bundle` resolves it, a hand-built path does not.
    static func url(_ language: String) -> URL? {
        for (bundle, folder) in [(Bundle.main, "\(language).lproj"), (Bundle.module, "Resources/\(language).lproj")] {
            if let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: folder) {
                return url
            }
        }
        return nil
    }
}

/// The text of `key` in the current language, with `%@`-style arguments; the key itself
/// when there is no translation.
func tr(_ key: String, _ arguments: CVarArg...) -> String {
    let format = L10n.table(L10n.language)?[key] ?? key
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}
