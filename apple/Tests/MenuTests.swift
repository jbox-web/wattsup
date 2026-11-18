import WattsUpCore
import XCTest
@testable import WattsUp

final class MenuTests: XCTestCase {
    override func tearDown() {
        L10n.forced = "en"
    }

    private func row(_ name: String, _ displayed: State?, polled: Bool = true) -> UpsRow {
        UpsRow(entry: entry(name), snapshot: polled ? snapshot(displayed ?? .unreachable) : nil, displayed: displayed, lastUpdate: nil)
    }

    func testTheSummaryCountsTheUpsesByState() {
        L10n.forced = "en"
        XCTAssertEqual(menuSummary(for: [row("A", .onMains), row("B", .onMains)]), "2 on mains")
        XCTAssertEqual(menuSummary(for: [row("A", .onMains), row("B", .onBattery)]), "1 on battery · 1 on mains")
        XCTAssertEqual(
            menuSummary(for: [row("A", .unreachable), row("B", .lowBattery), row("C", .onMains), row("D", .noData)]),
            "1 low battery · 1 no data · 1 unreachable · 1 on mains")
    }

    func testTheSummaryInFrench() {
        L10n.forced = "fr"
        XCTAssertEqual(menuSummary(for: [row("A", .onMains), row("B", .onBattery)]), "1 sur batterie · 1 sur secteur")
        XCTAssertEqual(menuSummary(for: []), "aucun onduleur")
    }

    func testTheSummaryOfUpsesOutOfReachOrNotPolledYet() {
        L10n.forced = "en"
        XCTAssertEqual(menuSummary(for: [row("A", nil), row("B", .onMains)]), "1 on mains · 1 out of reach")
        XCTAssertEqual(menuSummary(for: [row("A", nil, polled: false)]), "…")
        XCTAssertEqual(menuSummary(for: []), "no UPS")
    }

    func testEveryStateHasADotColor() {
        XCTAssertEqual(dotColor(for: row("A", .onMains)), .systemGreen)
        XCTAssertEqual(dotColor(for: row("A", .onBattery)), .systemOrange)
        XCTAssertEqual(dotColor(for: row("A", .lowBattery)), .systemRed)
        XCTAssertEqual(dotColor(for: row("A", .unreachable)), .systemRed)
        XCTAssertEqual(dotColor(for: row("A", .noData)), .systemRed)
        XCTAssertEqual(dotColor(for: row("A", nil)), .tertiaryLabelColor)
        XCTAssertEqual(dotColor(for: row("A", nil, polled: false)), .tertiaryLabelColor)
    }

    func testTheVersionShownInAbout() {
        XCTAssertEqual(aboutVersion(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2611181007"]), "0.1.0 (2611181007)")
        XCTAssertEqual(aboutVersion(["CFBundleShortVersionString": "0.1.0"]), "0.1.0")
        XCTAssertEqual(aboutVersion([:]), "–")
    }
}
