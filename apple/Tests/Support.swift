import Foundation
import WattsUpCore
@testable import WattsUp

func entry(_ name: String, publish: Bool = true, notifyUnreachable: Bool = true, username: String? = nil) -> UpsEntry {
    UpsEntry(
        name: name, host: "\(name.lowercased()).example", port: 3493, ups: "ups",
        publish: publish, notifyUnreachable: notifyUnreachable, username: username)
}

func snapshot(
    _ state: State, charge: UInt8? = nil, runtime: UInt32? = nil, load: UInt8? = nil, watts: UInt32? = nil,
    vars: [String: String] = [:], flags: [String] = [], extraFlags: [String] = [], error: String? = nil
) -> Snapshot {
    Snapshot(
        state: state, vars: vars, flags: flags, extraFlags: extraFlags, chargePercent: charge,
        runtimeSeconds: runtime, loadPercent: load, loadWatts: watts, model: nil, error: error)
}

/// A poller that answers from a table, optionally after a delay, and counts its calls.
final class FakePoller: Poller, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Snapshot] = [:]
    private var delays: [String: TimeInterval] = [:]
    private var passwords: [String: String?] = [:]
    private var counts: [String: Int] = [:]

    func calls(for name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[name] ?? 0
    }

    func set(_ name: String, _ snapshot: Snapshot, delay: TimeInterval = 0) {
        lock.lock()
        defer { lock.unlock() }
        answers[name] = snapshot
        delays[name] = delay
    }

    func passwordSeen(for name: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return passwords[name]
    }

    var names: Result<[UpsName], Error> = .success([])

    func listUps(host: String, port: UInt16) throws -> [UpsName] {
        try names.get()
    }

    func poll(entry: UpsEntry, password: String?) -> Snapshot {
        lock.lock()
        let answer = answers[entry.name] ?? snapshot(.unreachable, error: "no answer scripted")
        let delay = delays[entry.name] ?? 0
        passwords[entry.name] = password
        counts[entry.name, default: 0] += 1
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return answer
    }
}

/// A configuration file in a fresh temporary directory, removed with `cleanUp()`.
struct TemporaryConfig {
    let directory: URL
    var path: String { directory.appendingPathComponent("config.toml").path }

    init(_ entries: [UpsEntry], interval: UInt32 = 30) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wattsup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try saveConfig(config: Config(pollIntervalSeconds: interval, ups: entries), path: path)
    }

    func write(_ text: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Secrets kept in memory, for tests.
final class MemorySecrets: SecretStore {
    struct Refused: Error {}

    var stored: [String: String] = [:]
    /// Make the next writes or deletions fail, as a locked Keychain would.
    var failWrites = false
    var failDeletes = false

    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func password(service: String, account: String) throws -> String? {
        stored[key(service, account)]
    }

    func setPassword(_ password: String, service: String, account: String) throws {
        if failWrites { throw Refused() }
        stored[key(service, account)] = password
    }

    func delete(service: String, account: String) throws {
        if failDeletes { throw Refused() }
        stored[key(service, account)] = nil
    }
}
