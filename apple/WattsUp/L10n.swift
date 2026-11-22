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
    ///
    /// `resources` is a closure, looked at only when the app bundle has no strings: in the
    /// assembled app there is no SwiftPM resource bundle, and touching `Bundle.module` there
    /// is a fatal error (it stopped 0.1.1 at launch).
    static func url(_ language: String, app: Bundle = .main, resources: () -> Bundle = { .module }) -> URL? {
        let file = "Localizable"
        if let url = app.url(forResource: file, withExtension: "strings", subdirectory: "\(language).lproj") {
            return url
        }
        return resources().url(forResource: file, withExtension: "strings", subdirectory: "Resources/\(language).lproj")
    }
}

/// The text of `key` in the current language, with `%@`-style arguments; the key itself
/// when there is no translation.
func tr(_ key: String, _ arguments: CVarArg...) -> String {
    let format = L10n.table(L10n.language)?[key] ?? key
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}
