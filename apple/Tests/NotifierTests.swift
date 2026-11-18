import WattsUpCore
import XCTest
@testable import WattsUp

final class NotifierTests: XCTestCase {
    override func tearDown() {
        L10n.forced = "en"
    }

    private func text(_ event: Event, _ language: String, runtime: UInt32? = 2858) -> NotificationText {
        L10n.forced = language
        return notificationText(for: event, entry: entry("Maison"), snapshot: snapshot(.onBattery, runtime: runtime))
    }

    func testEnglishTexts() {
        XCTAssertEqual(text(.onBattery, "en"), NotificationText(title: "Maison", body: "On battery — 47 min left"))
        XCTAssertEqual(text(.onBattery, "en", runtime: nil).body, "On battery")
        XCTAssertEqual(text(.lowBattery, "en").body, "Battery low")
        XCTAssertEqual(text(.backOnMains, "en").body, "Back on mains power")
        XCTAssertEqual(text(.unreachable, "en").body, "Unreachable")
        XCTAssertEqual(text(.reachableAgain, "en").body, "Reachable again")
        XCTAssertEqual(text(.noData, "en").body, "The server has no fresh data from the UPS")
        XCTAssertEqual(text(.replaceBattery, "en").body, "Battery needs replacing")
    }

    func testFrenchTexts() {
        XCTAssertEqual(text(.onBattery, "fr"), NotificationText(title: "Maison", body: "Sur batterie — 47 min restantes"))
        XCTAssertEqual(text(.onBattery, "fr", runtime: nil).body, "Sur batterie")
        XCTAssertEqual(text(.lowBattery, "fr").body, "Batterie faible")
        XCTAssertEqual(text(.backOnMains, "fr").body, "Retour du secteur")
        XCTAssertEqual(text(.unreachable, "fr").body, "Injoignable")
        XCTAssertEqual(text(.reachableAgain, "fr").body, "De nouveau joignable")
        XCTAssertEqual(text(.noData, "fr").body, "Le serveur n'a pas de données récentes de l'onduleur")
        XCTAssertEqual(text(.replaceBattery, "fr").body, "Batterie à remplacer")
    }

    func testTheTitleIsTheUpsName() {
        L10n.forced = "en"
        XCTAssertEqual(notificationText(for: .lowBattery, entry: entry("Bureau"), snapshot: nil).title, "Bureau")
    }

    func testNothingIsNotifiedWhenNotificationsAreOff() {
        XCTAssertFalse(shouldNotify(.onBattery, entry: entry("Maison"), enabled: false))
        XCTAssertFalse(shouldNotify(.unreachable, entry: entry("Maison"), enabled: false))
    }

    func testReachabilityIsNotNotifiedForAUpsThatOptedOut() {
        let quiet = entry("Bureau", notifyUnreachable: false)
        for event in [Event.unreachable, .reachableAgain, .noData] {
            XCTAssertFalse(shouldNotify(event, entry: quiet, enabled: true), "\(event)")
            XCTAssertTrue(shouldNotify(event, entry: entry("Maison"), enabled: true), "\(event)")
        }
    }

    func testPowerEventsAreNotifiedEvenForAUpsThatOptedOutOfReachability() {
        let quiet = entry("Bureau", notifyUnreachable: false)
        for event in [Event.onBattery, .lowBattery, .backOnMains, .replaceBattery] {
            XCTAssertTrue(shouldNotify(event, entry: quiet, enabled: true), "\(event)")
        }
    }

    func testBothLanguagesHaveTheSameKeys() throws {
        let english = try XCTUnwrap(L10n.table("en"))
        let french = try XCTUnwrap(L10n.table("fr"))
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys).symmetricDifference(french.keys).sorted(), [])
    }

    func testEnglishIsItsOwnKey() throws {
        let english = try XCTUnwrap(L10n.table("en"))
        XCTAssertEqual(english.filter { $0.key != $0.value }.keys.sorted(), [])
    }

    func testTheInterfaceSpeaksFrench() {
        L10n.forced = "fr"
        let row = UpsRow(entry: entry("Maison"), snapshot: snapshot(.onMains, charge: 100, runtime: 3900), displayed: .onMains, lastUpdate: nil)
        XCTAssertEqual(menuTitle(for: row), "Maison — 100 % — sur secteur")
        XCTAssertEqual(summary(for: row).runtime, "1 h 05 min")
        XCTAssertEqual(flagLabel("RB"), "Batterie à remplacer")
        let outOfReach = UpsRow(entry: entry("Maison"), snapshot: snapshot(.unreachable), displayed: nil, lastUpdate: nil)
        XCTAssertEqual(stateLabel(for: outOfReach), "hors de portée")
    }

    func testAnUnknownKeyIsReturnedAsIs() {
        L10n.forced = "fr"
        XCTAssertEqual(tr("not a key"), "not a key")
    }
}
