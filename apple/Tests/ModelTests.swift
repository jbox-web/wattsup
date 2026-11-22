import AppKit
import WattsUpCore
import XCTest
@testable import WattsUp

@MainActor
final class ModelTests: XCTestCase {
    private var poller: FakePoller!
    private var config: TemporaryConfig!
    private var online = true
    private var published: [(String, Snapshot?)] = []
    private var events: [(String, [Event])] = []
    private var secrets: MemorySecrets!

    override func setUp() async throws {
        L10n.forced = "en"
        poller = FakePoller()
        secrets = MemorySecrets()
        online = true
        published = []
        events = []
    }

    override func tearDown() async throws {
        config?.cleanUp()
    }

    private func model(_ entries: [UpsEntry], keychainPrefix: String = "jbox.wattsup.") throws -> Model {
        config = try TemporaryConfig(entries)
        let model = Model(
            poller: poller, configPath: config.path, networkOnline: { [unowned self] in self.online },
            secrets: secrets, keychainPrefix: keychainPrefix,
            publish: { [unowned self] name, snapshot in self.published.append((name, snapshot)) })
        model.onEvents = { [unowned self] entry, events in self.events.append((entry.name, events)) }
        return model
    }

    func testLoadsOneRowPerConfiguredUps() throws {
        let model = try model([entry("Maison"), entry("Bureau")])
        XCTAssertEqual(model.rows.map(\.entry.name), ["Maison", "Bureau"])
        XCTAssertNil(model.rows[0].snapshot)
        XCTAssertNil(model.configError)
    }

    func testAPollFillsTheRow() async throws {
        let model = try model([entry("Maison")])
        poller.set("Maison", snapshot(.onMains, charge: 100))
        await model.pollOnce("Maison")
        XCTAssertEqual(model.rows[0].snapshot?.chargePercent, 100)
        XCTAssertEqual(model.rows[0].displayed, .onMains)
        XCTAssertNotNil(model.rows[0].lastUpdate)
    }

    func testOneUpsOnBatteryNeedsAttention() async throws {
        let model = try model([entry("Maison"), entry("Bureau")])
        poller.set("Maison", snapshot(.onMains))
        poller.set("Bureau", snapshot(.onBattery))
        await model.pollOnce("Maison")
        await model.pollOnce("Bureau")
        XCTAssertEqual(model.menuLook, .attention)
    }

    func testALowBatteryNeedsAttention() async throws {
        let model = try model([entry("Maison")])
        poller.set("Maison", snapshot(.lowBattery))
        await model.pollOnce("Maison")
        XCTAssertEqual(model.menuLook, .attention)
    }

    func testOneUnreachableUpsShowsUnreachable() async throws {
        let model = try model([entry("Maison"), entry("Bureau")])
        poller.set("Maison", snapshot(.onMains))
        poller.set("Bureau", snapshot(.onMains))
        await model.pollOnce("Maison")
        await model.pollOnce("Bureau")
        poller.set("Bureau", snapshot(.unreachable))
        for _ in 0..<3 { await model.pollOnce("Bureau") }
        XCTAssertEqual(model.rows[1].displayed, .unreachable)
        XCTAssertEqual(model.menuLook, .unreachable)
    }

    func testOnBatteryWinsOverUnreachable() async throws {
        let model = try model([entry("Maison"), entry("Bureau")])
        poller.set("Maison", snapshot(.onBattery))
        poller.set("Bureau", snapshot(.unreachable))
        await model.pollOnce("Maison")
        await model.pollOnce("Bureau")
        XCTAssertEqual(model.menuLook, .attention)
    }

    func testARefusalShowsAsUnreachableInTheMenuBar() async throws {
        let model = try model([entry("Maison")])
        poller.set("Maison", snapshot(.refused, error: "the server refused the request (ACCESS-DENIED)"))
        await model.pollOnce("Maison")
        XCTAssertEqual(model.rows[0].displayed, .refused)
        XCTAssertEqual(model.menuLook, .unreachable)
        XCTAssertNil(published.last?.1)
    }

    func testAllOnMainsIsAllGood() async throws {
        let model = try model([entry("Maison"), entry("Bureau")])
        poller.set("Maison", snapshot(.onMains))
        poller.set("Bureau", snapshot(.onMains))
        await model.pollOnce("Maison")
        await model.pollOnce("Bureau")
        XCTAssertEqual(model.menuLook, .allGood)
    }

    func testTheIconWaitsUntilAUpsHasAnswered() async throws {
        let model = try model([entry("Maison")])
        XCTAssertEqual(model.menuLook, .waiting)
        poller.set("Maison", snapshot(.onMains))
        await model.pollOnce("Maison")
        XCTAssertEqual(model.menuLook, .allGood)
    }

    func testTheIconWaitsWhileTheMacIsOffline() async throws {
        let model = try model([entry("Maison")])
        online = false
        poller.set("Maison", snapshot(.unreachable))
        await model.pollOnce("Maison")
        XCTAssertEqual(model.menuLook, .waiting)
    }

    func testTheKeychainIsReadOffTheMainThread() async throws {
        secrets.stored["jbox.wattsup.Maison|monuser"] = "secret"
        let model = try model([entry("Maison", username: "monuser")])
        poller.set("Maison", snapshot(.onMains))
        await model.pollOnce("Maison")
        XCTAssertFalse(secrets.readOnMainThread)
        XCTAssertEqual(poller.passwordSeen(for: "Maison"), .some(.some("secret")))
    }

    func testThePasswordIsReadOnceUntilTheNextReload() async throws {
        secrets.stored["jbox.wattsup.Maison|monuser"] = "secret"
        let model = try model([entry("Maison", username: "monuser")])
        poller.set("Maison", snapshot(.onMains))
        for _ in 0..<3 { await model.pollOnce("Maison") }
        XCTAssertEqual(secrets.reads, 1)
        model.reload()
        await model.pollOnce("Maison")
        XCTAssertEqual(secrets.reads, 2)
    }

    func testAKeychainThatRefusesIsNotAskedAgainAtEachPoll() async throws {
        secrets.failReads = true
        let model = try model([entry("Maison", username: "monuser")])
        poller.set("Maison", snapshot(.onMains))
        for _ in 0..<3 { await model.pollOnce("Maison") }
        XCTAssertEqual(secrets.reads, 1)
        XCTAssertEqual(model.rows[0].displayed, .refused)
    }

    func testAKeychainFailureIsNamedAsSuch() async throws {
        L10n.forced = "en"
        secrets.failReads = true
        let model = try model([entry("Maison", username: "monuser")])
        poller.set("Maison", snapshot(.onMains))
        await model.pollOnce("Maison")
        XCTAssertEqual(stateLabel(for: model.rows[0]), "password not readable from the Keychain")
        let text = notificationText(for: .refused, entry: entry("Maison"), snapshot: model.rows[0].snapshot)
        XCTAssertEqual(text.body, "The password cannot be read from the Keychain")
        XCTAssertEqual(model.rows[0].snapshot?.error?.components(separatedBy: "Keychain").count, 2)
    }

    func testAKeychainThatCannotBeReadIsReported() async throws {
        secrets.failReads = true
        let model = try model([entry("Maison", username: "monuser")])
        poller.set("Maison", snapshot(.onMains))
        await model.pollOnce("Maison")
        XCTAssertEqual(model.rows[0].displayed, .refused)
        XCTAssertTrue(model.rows[0].snapshot?.error?.contains("Keychain") ?? false, "\(String(describing: model.rows[0].snapshot?.error))")
    }

    func testATrialRunKeepsItsPasswordsApart() throws {
        let model = try model([], keychainPrefix: "jbox.wattsup-trial.")
        try model.add(entry("Maison", username: "monuser"), password: "secret")
        XCTAssertEqual(secrets.stored, ["jbox.wattsup-trial.Maison|monuser": "secret"])
    }

    func testTheModelIsReleasedWhileItsLoopsSleep() async throws {
        weak var released: Model?
        do {
            let model = try model([entry("Maison")])
            poller.set("Maison", snapshot(.onMains))
            model.start()
            try await Task.sleep(nanoseconds: 200_000_000)
            released = model
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(released)
    }

    func testNoUpsIsEmpty() throws {
        XCTAssertEqual(try model([]).menuLook, .empty)
    }

    func testAnOfflineMacPutsTheUpsOutOfReachWithoutEvents() async throws {
        let model = try model([entry("Maison")])
        poller.set("Maison", snapshot(.onMains))
        await model.pollOnce("Maison")
        online = false
        poller.set("Maison", snapshot(.unreachable))
        for _ in 0..<5 { await model.pollOnce("Maison") }
        XCTAssertNil(model.rows[0].displayed)
        XCTAssertEqual(model.menuLook, .waiting)
        XCTAssertTrue(events.isEmpty)
    }

    func testEventsReachTheObserver() async throws {
        let model = try model([entry("Maison")])
        poller.set("Maison", snapshot(.onMains))
        await model.pollOnce("Maison")
        poller.set("Maison", snapshot(.onBattery))
        await model.pollOnce("Maison")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, "Maison")
        XCTAssertEqual(events.first?.1, [.onBattery])
    }

    func testASlowUpsDoesNotDelayTheOther() async throws {
        let model = try model([entry("Lent"), entry("Rapide")])
        poller.set("Lent", snapshot(.onMains), delay: 2)
        poller.set("Rapide", snapshot(.onMains, charge: 80))
        model.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.rows[1].snapshot?.chargePercent, 80)
        XCTAssertNil(model.rows[0].snapshot)
        model.stop()
    }

    func testPublishesOnlyTheUpsesThatAskForIt() async throws {
        let model = try model([entry("Maison"), entry("Bureau", publish: false)])
        poller.set("Maison", snapshot(.onMains, charge: 100))
        poller.set("Bureau", snapshot(.onMains, charge: 50))
        await model.pollOnce("Maison")
        await model.pollOnce("Bureau")
        XCTAssertEqual(published.map(\.0), ["Maison", "Bureau"])
        XCTAssertEqual(published[0].1?.chargePercent, 100)
        XCTAssertNil(published[1].1)
    }

    func testAnOutOfReachUpsIsWithdrawnFromTheWidget() async throws {
        let model = try model([entry("Maison")])
        online = false
        poller.set("Maison", snapshot(.unreachable))
        await model.pollOnce("Maison")
        XCTAssertEqual(published.count, 1)
        XCTAssertNil(published[0].1)
    }

    func testOneLostPollKeepsTheWidgetLine() async throws {
        let model = try model([entry("Maison")])
        poller.set("Maison", snapshot(.onMains, charge: 100))
        await model.pollOnce("Maison")
        poller.set("Maison", snapshot(.unreachable))
        await model.pollOnce("Maison")
        XCTAssertEqual(published.count, 1)
        await model.pollOnce("Maison")
        await model.pollOnce("Maison")
        XCTAssertEqual(published.count, 2)
        XCTAssertNil(published[1].1)
    }

    func testTheMacIsOfflineWithoutANetworkPathOrRightAfterWaking() {
        XCTAssertTrue(NetworkWatch.isOnline(pathSatisfied: true, secondsSinceWake: 31))
        XCTAssertTrue(NetworkWatch.isOnline(pathSatisfied: true, secondsSinceWake: nil))
        XCTAssertFalse(NetworkWatch.isOnline(pathSatisfied: true, secondsSinceWake: 10))
        XCTAssertFalse(NetworkWatch.isOnline(pathSatisfied: false, secondsSinceWake: 100))
    }

    func testAnInvalidConfigurationIsReportedAndLeavesNoRows() throws {
        config = try TemporaryConfig([entry("Maison")])
        try config.write("[[ups]\n")
        let model = Model(
            poller: poller, configPath: config.path, networkOnline: { true }, secrets: secrets, publish: { _, _ in })
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.configError?.contains(config.path) ?? false, model.configError ?? "nil")
        XCTAssertEqual(model.menuLook, .empty)
    }

    func testReloadPicksUpANewEntryAndWithdrawsARemovedOne() async throws {
        let model = try model([entry("Maison")])
        poller.set("Maison", snapshot(.onMains, charge: 100))
        await model.pollOnce("Maison")
        try saveConfig(config: Config(pollIntervalSeconds: 30, ups: [entry("Bureau")]), path: config.path)
        published = []
        model.reload()
        XCTAssertEqual(model.rows.map(\.entry.name), ["Bureau"])
        XCTAssertEqual(published.map(\.0), ["Maison"])
        XCTAssertNil(published[0].1)
    }

    func testThePasswordOfAnEntryIsHandedToThePoller() async throws {
        secrets.stored["jbox.wattsup.Maison|monuser"] = "secret"
        let model = try model([entry("Maison", username: "monuser")])
        poller.set("Maison", snapshot(.onMains))
        await model.pollOnce("Maison")
        XCTAssertEqual(poller.passwordSeen(for: "Maison"), .some(.some("secret")))
    }

    func testAddingAUpsWritesTheFileAndShowsTheRow() throws {
        let model = try model([entry("Maison")])
        try model.add(entry("Bureau"), password: nil)
        XCTAssertEqual(model.rows.map(\.entry.name), ["Maison", "Bureau"])
        XCTAssertEqual(try loadConfig(path: config.path).ups.map(\.name), ["Maison", "Bureau"])
    }

    func testAddingANameAlreadyTakenFailsAndLeavesTheFileUntouched() throws {
        let model = try model([entry("Maison")])
        let before = try String(contentsOfFile: config.path, encoding: .utf8)
        XCTAssertThrowsError(try model.add(entry("maison"), password: "secret"))
        XCTAssertEqual(try String(contentsOfFile: config.path, encoding: .utf8), before)
        XCTAssertEqual(model.rows.map(\.entry.name), ["Maison"])
        XCTAssertTrue(secrets.stored.isEmpty)
    }

    func testThePasswordGoesToTheKeychainNeverToTheFile() throws {
        let model = try model([])
        try model.add(entry("Maison", username: "monuser"), password: "secret")
        XCTAssertEqual(secrets.stored, ["jbox.wattsup.Maison|monuser": "secret"])
        XCTAssertFalse(try String(contentsOfFile: config.path, encoding: .utf8).contains("secret"))
    }

    func testRenamingAUpsMovesItsPassword() throws {
        let model = try model([])
        try model.add(entry("Maison", username: "monuser"), password: "secret")
        try model.update("Maison", with: entry("Garage", username: "monuser"), password: nil)
        XCTAssertEqual(secrets.stored, ["jbox.wattsup.Garage|monuser": "secret"])
        XCTAssertEqual(model.rows.map(\.entry.name), ["Garage"])
    }

    func testEditingWithANewPasswordReplacesIt() throws {
        let model = try model([])
        try model.add(entry("Maison", username: "monuser"), password: "secret")
        try model.update("Maison", with: entry("Maison", username: "autre"), password: "nouveau")
        XCTAssertEqual(secrets.stored, ["jbox.wattsup.Maison|autre": "nouveau"])
    }

    func testRemovingTheUsernameRemovesThePassword() throws {
        let model = try model([])
        try model.add(entry("Maison", username: "monuser"), password: "secret")
        try model.update("Maison", with: entry("Maison"), password: nil)
        XCTAssertTrue(secrets.stored.isEmpty)
        XCTAssertNil(model.rows[0].entry.username)
    }

    func testAFailedEditLeavesThePasswordWhereItWas() throws {
        let model = try model([entry("Bureau")])
        try model.add(entry("Maison", username: "monuser"), password: "secret")
        XCTAssertThrowsError(try model.update("Maison", with: entry("Bureau", username: "monuser"), password: nil))
        XCTAssertEqual(secrets.stored, ["jbox.wattsup.Maison|monuser": "secret"])
        XCTAssertEqual(model.rows.map(\.entry.name), ["Bureau", "Maison"])
    }

    func testRemovingAUpsRemovesItsRowItsEntryAndItsPassword() throws {
        let model = try model([entry("Bureau")])
        try model.add(entry("Maison", username: "monuser"), password: "secret")
        try model.remove("Maison")
        XCTAssertEqual(model.rows.map(\.entry.name), ["Bureau"])
        XCTAssertEqual(try loadConfig(path: config.path).ups.map(\.name), ["Bureau"])
        XCTAssertTrue(secrets.stored.isEmpty)
    }

    func testThePollIntervalIsSaved() throws {
        let model = try model([entry("Maison")])
        try model.setPollInterval(60)
        XCTAssertEqual(model.pollIntervalSeconds, 60)
        XCTAssertEqual(try loadConfig(path: config.path).pollIntervalSeconds, 60)
        XCTAssertThrowsError(try model.setPollInterval(1))
        XCTAssertEqual(model.pollIntervalSeconds, 60)
    }

    func testTestingAConnectionListsTheNamesOrExplainsTheFailure() async throws {
        let model = try model([])
        poller.names = .success([UpsName(name: "ups", description: "Garage")])
        let found = await model.testConnection(host: "nas.example", port: 3500)
        XCTAssertEqual(try found.get().map(\.name), ["ups"])
        XCTAssertEqual(poller.listedServer?.host, "nas.example")
        XCTAssertEqual(poller.listedServer?.port, 3500)
        poller.names = .failure(CoreError.Server(message: "unreachable: connection refused"))
        let failed = await model.testConnection(host: "nas.example", port: 3493)
        guard case .failure(let message) = failed else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.reason.contains("connection refused"), message.reason)
    }

    func testAnInvalidFileIsNeverOverwritten() throws {
        let model = try model([entry("Maison")])
        let broken = "[[ups]\nname = \"Maison\"\n"
        try config.write(broken)
        model.reload()
        XCTAssertNotNil(model.configError)
        XCTAssertThrowsError(try model.add(entry("Bureau"), password: nil))
        XCTAssertThrowsError(try model.setPollInterval(60))
        XCTAssertEqual(try String(contentsOfFile: config.path, encoding: .utf8), broken)
    }

    func testAFileBrokenWhileTheAppRunsIsNotOverwrittenEither() throws {
        let model = try model([entry("Maison")])
        let broken = "[[ups]\n"
        try config.write(broken)
        XCTAssertThrowsError(try model.add(entry("Bureau"), password: nil))
        XCTAssertThrowsError(try model.remove("Maison"))
        XCTAssertEqual(try String(contentsOfFile: config.path, encoding: .utf8), broken)
    }

    func testAnEntryAddedByHandSurvivesASaveByTheApp() throws {
        let model = try model([entry("Maison")])
        try saveConfig(config: Config(pollIntervalSeconds: 45, ups: [entry("Maison"), entry("Garage")]), path: config.path)
        try model.add(entry("Bureau"), password: nil)
        let saved = try loadConfig(path: config.path)
        XCTAssertEqual(saved.ups.map(\.name), ["Maison", "Garage", "Bureau"])
        XCTAssertEqual(saved.pollIntervalSeconds, 45)
        XCTAssertEqual(model.rows.map(\.entry.name), ["Maison", "Garage", "Bureau"])
    }

    func testAResultArrivingAfterStopIsDropped() async throws {
        let model = try model([entry("Maison")])
        poller.set("Maison", snapshot(.onMains, charge: 100), delay: 0.3)
        let poll = Task { await model.pollOnce("Maison") }
        try await Task.sleep(nanoseconds: 50_000_000)
        model.stop()
        await poll.value
        XCTAssertNil(model.rows[0].snapshot)
        XCTAssertTrue(published.isEmpty)
    }

    func testALateResultDoesNotOverwriteANewerOne() async throws {
        let model = try model([entry("Maison")])
        poller.set("Maison", snapshot(.onMains))
        await model.pollOnce("Maison")
        // A slow poll that still says "on mains" is overtaken by one that sees the cut.
        poller.set("Maison", snapshot(.onMains), delay: 0.3)
        let slow = Task { await model.pollOnce("Maison") }
        try await Task.sleep(nanoseconds: 50_000_000)
        poller.set("Maison", snapshot(.onBattery))
        await model.pollOnce("Maison")
        await slow.value
        XCTAssertEqual(model.rows[0].displayed, .onBattery)
        XCTAssertEqual(events.map(\.1), [[.onBattery]])
    }

    func testReloadingLeavesTheLoopsOfUnchangedEntriesAlone() async throws {
        let model = try model([entry("Maison")])
        poller.set("Maison", snapshot(.onMains))
        model.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(poller.calls(for: "Maison"), 1)
        model.reload()
        model.reload()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(poller.calls(for: "Maison"), 1)
        model.stop()
    }

    func testARenameWhosePasswordCannotBeStoredChangesNothing() throws {
        let model = try model([])
        try model.add(entry("Maison", username: "monuser"), password: "secret")
        let before = try String(contentsOfFile: config.path, encoding: .utf8)
        secrets.failWrites = true
        XCTAssertThrowsError(try model.update("Maison", with: entry("Garage", username: "monuser"), password: nil))
        XCTAssertEqual(secrets.stored, ["jbox.wattsup.Maison|monuser": "secret"])
        XCTAssertEqual(try String(contentsOfFile: config.path, encoding: .utf8), before)
        XCTAssertEqual(model.rows.map(\.entry.name), ["Maison"])
    }

    func testARemovalWhosePasswordCannotBeDeletedStillRemovesTheUps() throws {
        let model = try model([])
        try model.add(entry("Maison", username: "monuser"), password: "secret")
        secrets.failDeletes = true
        XCTAssertThrowsError(try model.remove("Maison"))
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(try loadConfig(path: config.path).ups.isEmpty)
    }

    func testAnAdditionWhosePasswordCannotBeStoredStillShowsTheUps() throws {
        let model = try model([])
        secrets.failWrites = true
        XCTAssertThrowsError(try model.add(entry("Maison", username: "monuser"), password: "secret"))
        XCTAssertEqual(model.rows.map(\.entry.name), ["Maison"])
    }

    func testTheKeychainStoresReplacesAndDeletesAPassword() throws {
        let keychain = Keychain()
        let service = "jbox.wattsup.test-\(UUID().uuidString)"
        defer { try? keychain.delete(service: service, account: "monuser") }
        XCTAssertNil(try keychain.password(service: service, account: "monuser"))
        try keychain.setPassword("secret", service: service, account: "monuser")
        XCTAssertEqual(try keychain.password(service: service, account: "monuser"), "secret")
        try keychain.setPassword("nouveau", service: service, account: "monuser")
        XCTAssertEqual(try keychain.password(service: service, account: "monuser"), "nouveau")
        try keychain.delete(service: service, account: "monuser")
        XCTAssertNil(try keychain.password(service: service, account: "monuser"))
        XCTAssertNoThrow(try keychain.delete(service: service, account: "monuser"))
    }

    func testMenuTitles() {
        let full = UpsRow(entry: entry("Maison"), snapshot: snapshot(.onMains, charge: 100), displayed: .onMains, lastUpdate: nil)
        XCTAssertEqual(menuTitle(for: full), "Maison — 100 % — on mains")
        let noCharge = UpsRow(entry: entry("Maison"), snapshot: snapshot(.onMains), displayed: .onMains, lastUpdate: nil)
        XCTAssertEqual(menuTitle(for: noCharge), "Maison — on mains")
        let unreachable = UpsRow(
            entry: entry("Bureau"), snapshot: snapshot(.unreachable), displayed: .unreachable, lastUpdate: nil)
        XCTAssertEqual(menuTitle(for: unreachable), "Bureau — unreachable")
        let outOfReach = UpsRow(entry: entry("Bureau"), snapshot: snapshot(.unreachable), displayed: nil, lastUpdate: nil)
        XCTAssertEqual(menuTitle(for: outOfReach), "Bureau — out of reach")
        let waiting = UpsRow(entry: entry("Bureau"), snapshot: nil, displayed: nil, lastUpdate: nil)
        XCTAssertEqual(menuTitle(for: waiting), "Bureau — …")
    }

    func testEveryMenuLookHasAnIcon() {
        for look in [MenuLook.allGood, .attention, .unreachable, .empty] {
            XCTAssertNotNil(menuIcon(for: look), "\(look)")
        }
    }
}
