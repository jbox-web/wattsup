import WattsUpCore
import XCTest
@testable import WattsUp

final class WindowTests: XCTestCase {
    override func setUp() {
        L10n.forced = "en"
    }

    private func row(_ snapshot: Snapshot?, displayed: State?) -> UpsRow {
        UpsRow(entry: entry("Maison"), snapshot: snapshot, displayed: displayed, lastUpdate: nil)
    }

    func testSummaryOfAUpsOnMains() {
        let summary = summary(for: row(snapshot(.onMains, charge: 100, runtime: 2858, load: 10, watts: 52), displayed: .onMains))
        XCTAssertEqual(summary.state, "on mains")
        XCTAssertEqual(summary.charge, "100 %")
        XCTAssertEqual(summary.runtime, "47 min")
        XCTAssertEqual(summary.load, "10 % (52 W)")
    }

    func testLoadWithoutWatts() {
        let summary = summary(for: row(snapshot(.onMains, load: 10), displayed: .onMains))
        XCTAssertEqual(summary.load, "10 %")
    }

    func testMissingValuesAreAbsent() {
        let summary = summary(for: row(snapshot(.onBattery), displayed: .onBattery))
        XCTAssertEqual(summary.state, "on battery")
        XCTAssertNil(summary.charge)
        XCTAssertNil(summary.runtime)
        XCTAssertNil(summary.load)
    }

    func testALongRuntimeIsInHours() {
        XCTAssertEqual(summary(for: row(snapshot(.onMains, runtime: 3900), displayed: .onMains)).runtime, "1 h 05 min")
        XCTAssertEqual(summary(for: row(snapshot(.onMains, runtime: 59), displayed: .onMains)).runtime, "0 min")
    }

    func testAnOutOfReachUpsShowsNoValues() {
        let summary = summary(for: row(snapshot(.unreachable), displayed: nil))
        XCTAssertEqual(summary.state, "out of reach")
        XCTAssertNil(summary.charge)
    }

    func testOneLostPollKeepsNothingStaleOnScreen() {
        // The last poll failed but the UPS is not declared unreachable yet: no values to show.
        let summary = summary(for: row(snapshot(.unreachable), displayed: .onMains))
        XCTAssertEqual(summary.state, "on mains")
        XCTAssertNil(summary.charge)
        XCTAssertNil(summary.runtime)
    }

    func testBeforeTheFirstPoll() {
        let summary = summary(for: row(nil, displayed: nil))
        XCTAssertEqual(summary.state, "…")
        XCTAssertNil(summary.charge)
    }

    func testVariablesAreSortedByName() {
        let vars = ["ups.status": "OL", "battery.charge": "100", "input.voltage": "228.0"]
        let rows = variableRows(for: row(snapshot(.onMains, vars: vars), displayed: .onMains), filter: "")
        XCTAssertEqual(rows.map(\.name), ["battery.charge", "input.voltage", "ups.status"])
        XCTAssertEqual(rows.map(\.value), ["100", "228.0", "OL"])
    }

    func testTheFilterMatchesNamesWhateverTheCase() {
        let vars = ["ups.status": "OL", "battery.charge": "100", "battery.runtime": "2858"]
        let rows = variableRows(for: row(snapshot(.onMains, vars: vars), displayed: .onMains), filter: " BATT ")
        XCTAssertEqual(rows.map(\.name), ["battery.charge", "battery.runtime"])
    }

    func testTheFilterAlsoMatchesValues() {
        let vars = ["device.mfr": "American Power Conversion", "ups.status": "OL"]
        let rows = variableRows(for: row(snapshot(.onMains, vars: vars), displayed: .onMains), filter: "american")
        XCTAssertEqual(rows.map(\.name), ["device.mfr"])
    }

    func testNoVariablesBeforeTheFirstPoll() {
        XCTAssertTrue(variableRows(for: row(nil, displayed: nil), filter: "").isEmpty)
    }
}
