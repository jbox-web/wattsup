import XCTest
@testable import WattsUp

final class L10nTests: XCTestCase {
    func testTheFirstSupportedPreferredLanguageWins() {
        XCTAssertEqual(L10n.resolve(preferred: ["de-DE", "fr-FR"]), "fr")
        XCTAssertEqual(L10n.resolve(preferred: ["fr-CA", "en-US"]), "fr")
        XCTAssertEqual(L10n.resolve(preferred: ["en-GB", "fr-FR"]), "en")
    }

    func testEnglishWhenNoPreferredLanguageIsSupported() {
        XCTAssertEqual(L10n.resolve(preferred: ["de-DE", "ja-JP"]), "en")
        XCTAssertEqual(L10n.resolve(preferred: []), "en")
    }

    /// In the assembled app there is no SwiftPM resource bundle, and touching `Bundle.module`
    /// there is a fatal error: it must not even be looked at when the app has the strings.
    func testTheAppBundleIsEnoughWithoutTouchingTheResourceBundle() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("wattsup-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: app) }
        let strings = app.appendingPathComponent("Contents/Resources/fr.lproj")
        try FileManager.default.createDirectory(at: strings, withIntermediateDirectories: true)
        try "\"on mains\" = \"sur secteur\";\n".write(
            to: strings.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let bundle = try XCTUnwrap(Bundle(path: app.path))

        let url = L10n.url("fr", app: bundle, resources: {
            XCTFail("the resource bundle was looked at")
            return Bundle.main
        })

        XCTAssertEqual(url?.lastPathComponent, "Localizable.strings")
    }

    func testTheResourceBundleIsTheFallback() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("wattsup-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let bundle = try XCTUnwrap(Bundle(path: empty.path))

        XCTAssertNotNil(L10n.url("fr", app: bundle, resources: { Bundle.module }))
    }
}
