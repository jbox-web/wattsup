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
}
