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
    private var listed: (host: String, port: UInt16)?
    var listedServer: (host: String, port: UInt16)? {
        lock.lock()
        defer { lock.unlock() }
        return listed
    }

    func listUps(host: String, port: UInt16) throws -> [UpsName] {
        lock.lock()
        listed = (host, port)
        lock.unlock()
        return try names.get()
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
/// Secrets kept in memory, for tests. Reads come from the poll threads, the rest from the
/// test: every access goes through the lock.
final class MemorySecrets: SecretStore, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var _stored: [String: String] = [:]
    private var _failWrites = false
    private var _failDeletes = false
    private var _failReads = false
    private var _readOnMainThread = false
    private var _reads = 0

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var stored: [String: String] {
        get { locked { _stored } }
        set { locked { _stored = newValue } }
    }
    /// Make the next writes, deletions or reads fail, as a locked Keychain would.
    var failWrites: Bool {
        get { locked { _failWrites } }
        set { locked { _failWrites = newValue } }
    }
    var failDeletes: Bool {
        get { locked { _failDeletes } }
        set { locked { _failDeletes = newValue } }
    }
    var failReads: Bool {
        get { locked { _failReads } }
        set { locked { _failReads = newValue } }
    }
    /// Whether a read happened on the main thread.
    var readOnMainThread: Bool { locked { _readOnMainThread } }
    /// How many times a password was read.
    var reads: Int { locked { _reads } }

    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func password(service: String, account: String) throws -> String? {
        try locked {
            _reads += 1
            if Thread.isMainThread { _readOnMainThread = true }
            if _failReads { throw Refused() }
            return _stored[key(service, account)]
        }
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
