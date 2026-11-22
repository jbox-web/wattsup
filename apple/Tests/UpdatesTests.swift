import XCTest
@testable import WattsUp

final class UpdatesTests: XCTestCase {
    private var made: [URL] = []

    override func tearDown() {
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
    }

    /// A bundle at `name` whose Info.plist holds `info`.
    private func bundle(_ name: String, info: [String: Any]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wattsup-\(UUID().uuidString)")
        made.append(root)
        let path = root.appendingPathComponent(name)
        let contents = path.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(path: path.path))
    }

    private let sparkle: [String: Any] = [
        "CFBundleIdentifier": "fr.nicoladmin.wattsup",
        "SUFeedURL": "https://github.com/jbox-web/wattsup/releases/latest/download/appcast.xml",
        "SUPublicEDKey": "c29tZSBwdWJsaWMga2V5IG9mIDMyIGJ5dGVzIGxvbmcu",
    ]

    func testAnAssembledAppWithAFeedAndAKeyCanUpdate() throws {
        XCTAssertTrue(Updates.canUpdate(try bundle("Watt's Up.app", info: sparkle)))
    }

    func testNoUpdatesWithoutAPublicKey() throws {
        var info = sparkle
        info["SUPublicEDKey"] = nil
        XCTAssertFalse(Updates.canUpdate(try bundle("Watt's Up.app", info: info)))
        info["SUPublicEDKey"] = ""
        XCTAssertFalse(Updates.canUpdate(try bundle("Watt's Up.app", info: info)))
    }

    func testNoUpdatesWithoutAFeed() throws {
        var info = sparkle
        info["SUFeedURL"] = nil
        XCTAssertFalse(Updates.canUpdate(try bundle("Watt's Up.app", info: info)))
    }

    /// `swift run` and the tests run outside an .app: nothing to replace.
    func testNoUpdatesOutsideAnApp() throws {
        XCTAssertFalse(Updates.canUpdate(try bundle("WattsUp", info: sparkle)))
    }

    /// apple/launch-check.sh starts the assembled app: it must not reach for the feed.
    func testUpdatesCanBeTurnedOffByTheEnvironment() throws {
        let app = try bundle("Watt's Up.app", info: sparkle)
        XCTAssertFalse(Updates.canUpdate(app, environment: ["WATTSUP_NO_UPDATES": "1"]))
        XCTAssertTrue(Updates.canUpdate(app, environment: ["WATTSUP_CONFIG": "/tmp/x.toml"]))
    }

    @MainActor
    func testStartingOutsideAnAppLeavesUpdatesOff() {
        let updates = Updates()
        updates.start()
        XCTAssertFalse(updates.available)
        XCTAssertFalse(updates.checksAutomatically)
        updates.checksAutomatically = true
        XCTAssertFalse(updates.checksAutomatically)
        // Does nothing, and must not crash.
        updates.checkNow()
    }
}
