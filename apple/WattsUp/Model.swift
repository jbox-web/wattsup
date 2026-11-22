import Combine
import Foundation
import WattsUpCore

/// Reads one UPS. The app uses the Rust core; tests use a double.
protocol Poller: Sendable {
    /// Blocking; a failure is a snapshot, never an error.
    func poll(entry: UpsEntry, password: String?) -> Snapshot
    /// The UPS names a server offers. Blocking.
    func listUps(host: String, port: UInt16) throws -> [UpsName]
}

struct CorePoller: Poller {
    func poll(entry: UpsEntry, password: String?) -> Snapshot {
        WattsUpCore.poll(entry: entry, password: password)
    }

    func listUps(host: String, port: UInt16) throws -> [UpsName] {
        try WattsUpCore.listUps(host: host, port: port)
    }
}

/// Why a server could not be asked for its UPS names.
struct ConnectionFailure: Error {
    let reason: String
}

/// One configured UPS and what is known of it.
struct UpsRow: Identifiable {
    let entry: UpsEntry
    /// The last poll, whatever its outcome; nil before the first one.
    var snapshot: Snapshot?
    /// The state to show; nil before the first poll, and while the UPS is out of reach
    /// because the Mac itself is offline.
    var displayed: State?
    var lastUpdate: Date?

    var id: String { entry.name }
}

/// What the menu bar icon says.
enum MenuLook {
    case allGood, attention, unreachable, empty
}

/// The configured UPSes, polled each on its own task so that sites stay independent.
@MainActor
final class Model: ObservableObject {
    @Published private(set) var rows: [UpsRow] = []
    @Published private(set) var configError: String?
    private(set) var pollIntervalSeconds: UInt32 = 30
    /// Called with the changes worth a notification.
    var onEvents: ((UpsEntry, [Event]) -> Void)?

    let configPath: String
    private let poller: Poller
    private let networkOnline: () -> Bool
    private let secrets: SecretStore
    private let publish: (String, Snapshot?) -> Void
    private var trackers: [String: Tracker] = [:]
    private var passwords: [String: String] = [:]
    private var loops: [String: Task<Void, Never>] = [:]
    /// The poll whose result is still wanted, per UPS; any other result is dropped.
    private var awaited: [String: UUID] = [:]
    private var running = false

    /// - Parameters:
    ///   - networkOnline: false when the Mac has no network path or has just woken up.
    ///   - secrets: where the NUT passwords of entries that have a username live.
    ///   - publish: shows a UPS in the Batteries widget; nil withdraws it.
    init(
        poller: Poller, configPath: String, networkOnline: @escaping () -> Bool,
        secrets: SecretStore, publish: @escaping (String, Snapshot?) -> Void
    ) {
        self.poller = poller
        self.configPath = configPath
        self.networkOnline = networkOnline
        self.secrets = secrets
        self.publish = publish
        reload()
    }

    var menuLook: MenuLook {
        if rows.isEmpty { return .empty }
        switch worst(states: rows.compactMap(\.displayed)) {
        case .lowBattery, .onBattery: return .attention
        case .unreachable, .noData, .refused: return .unreachable
        case .onMains, nil: return .allGood
        }
    }

    func start() {
        running = true
        rows.forEach { startLoop($0.entry.name) }
    }

    func stop() {
        running = false
        loops.values.forEach { $0.cancel() }
        loops = [:]
        awaited = [:]
    }

    /// Reads the configuration again. Entries that did not change keep what is known of them.
    func reload() {
        var entries: [UpsEntry] = []
        do {
            let config = try loadConfig(path: configPath)
            entries = config.ups
            pollIntervalSeconds = config.pollIntervalSeconds
            configError = nil
        } catch {
            configError = error.localizedDescription
        }

        let kept = Dictionary(uniqueKeysWithValues: rows.map { ($0.entry.name, $0) })
            .filter { name, row in entries.contains { $0.name == name && $0 == row.entry } }
        for row in rows where kept[row.entry.name] == nil {
            trackers[row.entry.name] = nil
            loops.removeValue(forKey: row.entry.name)?.cancel()
            awaited[row.entry.name] = nil
            publish(row.entry.name, nil)
        }
        rows = entries.map { kept[$0.name] ?? UpsRow(entry: $0) }
        passwords = [:]
        for entry in entries {
            guard let username = entry.username else { continue }
            passwords[entry.name] = try? secrets.password(service: keychainService(name: entry.name), account: username)
        }
        if running {
            // Entries that did not change keep their loop: restarting it would poll again at
            // once, and a few reloads in a row would defeat the three-failures rule.
            for row in rows where loops[row.entry.name] == nil {
                startLoop(row.entry.name)
            }
        }
    }

    /// Polls one UPS once, off the main thread, and records the result.
    func pollOnce(_ name: String) async {
        guard let entry = rows.first(where: { $0.entry.name == name })?.entry else { return }
        let poller = self.poller
        let password = passwords[name]
        let token = UUID()
        awaited[name] = token
        // A blocking call: on a thread of its own, not on Swift's cooperative pool, so that a
        // site that times out never holds back the polls of the others.
        let snapshot = await withCheckedContinuation { (continuation: CheckedContinuation<Snapshot, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: poller.poll(entry: entry, password: password))
            }
        }
        // Stopped, reloaded or overtaken by a newer poll meanwhile: the result is stale.
        guard awaited[name] == token else { return }
        awaited[name] = nil
        record(snapshot, for: entry)
    }

    // MARK: - Editing the configuration

    /// Adds a UPS. Nothing is written when the configuration would be invalid.
    func add(_ entry: UpsEntry, password: String?) throws {
        try edit { $0.ups.append(entry) }
        defer { reload() }
        try store(password, for: entry)
    }

    /// Replaces the UPS named `old`. A nil password keeps the current one, moved to the
    /// new name or username when they changed.
    func update(_ old: String, with entry: UpsEntry, password: String?) throws {
        guard let previous = rows.first(where: { $0.entry.name == old })?.entry else { return }
        let oldKey = previous.username.map { (service: keychainService(name: previous.name), account: $0) }
        let newKey = entry.username.map { (service: keychainService(name: entry.name), account: $0) }
        let moved = oldKey?.service != newKey?.service || oldKey?.account != newKey?.account
        let kept = try oldKey.flatMap { try secrets.password(service: $0.service, account: $0.account) }

        // The new password goes in first and the old one out last: whatever fails, the
        // password is never lost, and a refused Keychain changes nothing at all.
        let wanted = password ?? kept
        let written = try newKey != nil && (moved || password != nil) && store(wanted, for: entry)
        do {
            try edit { config in
                config.ups = config.ups.map { $0.name == old ? entry : $0 }
            }
        } catch {
            if written, moved, let newKey { try? secrets.delete(service: newKey.service, account: newKey.account) }
            throw error
        }
        defer { reload() }
        if moved, let oldKey { try secrets.delete(service: oldKey.service, account: oldKey.account) }
    }

    func remove(_ name: String) throws {
        guard let entry = rows.first(where: { $0.entry.name == name })?.entry else { return }
        try edit { $0.ups.removeAll { $0.name == name } }
        defer { reload() }
        if let username = entry.username {
            try secrets.delete(service: keychainService(name: name), account: username)
        }
    }

    func setPollInterval(_ seconds: UInt32) throws {
        try edit { $0.pollIntervalSeconds = seconds }
        reload()
    }

    /// Asks a server for its UPS names, off the main thread.
    func testConnection(host: String, port: UInt16) async -> Result<[UpsName], ConnectionFailure> {
        let poller = self.poller
        return await Task.detached {
            do {
                return .success(try poller.listUps(host: host, port: port))
            } catch {
                return .failure(ConnectionFailure(reason: error.localizedDescription))
            }
        }.value
    }

    /// Applies a change to the file as it is on disk now, not to what was read at launch:
    /// an entry added by hand meanwhile is kept, and a file that cannot be read is never
    /// replaced.
    private func edit(_ change: (inout Config) -> Void) throws {
        var config = try loadConfig(path: configPath)
        change(&config)
        try saveConfig(config: config, path: configPath)
    }

    /// True when a password was written.
    @discardableResult
    private func store(_ password: String?, for entry: UpsEntry) throws -> Bool {
        guard let username = entry.username, let password, !password.isEmpty else { return false }
        try secrets.setPassword(password, service: keychainService(name: entry.name), account: username)
        return true
    }

    private func record(_ snapshot: Snapshot, for entry: UpsEntry) {
        // The entry may have been edited or removed while the poll was running.
        guard let index = rows.firstIndex(where: { $0.entry == entry }) else { return }
        let tracker = trackers[entry.name] ?? Tracker()
        trackers[entry.name] = tracker
        let events = tracker.observe(snapshot: snapshot, macOnline: networkOnline())
        let displayed = tracker.displayed()
        rows[index].snapshot = snapshot
        rows[index].displayed = displayed
        rows[index].lastUpdate = Date()

        let fresh = ![.unreachable, .noData, .refused].contains(snapshot.state)
        if !entry.publish || displayed == nil {
            publish(entry.name, nil)
        } else if fresh {
            publish(entry.name, snapshot)
        } else if displayed == .unreachable || displayed == .noData || displayed == .refused {
            // Declared, not just one lost poll: the line would show stale values.
            publish(entry.name, nil)
        }
        if !events.isEmpty { onEvents?(entry, events) }
    }

    private func startLoop(_ name: String) {
        loops[name]?.cancel()
        loops[name] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce(name)
                let interval = UInt64(self.pollIntervalSeconds) * 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }
}

extension UpsRow {
    init(entry: UpsEntry) {
        self.init(entry: entry, snapshot: nil, displayed: nil, lastUpdate: nil)
    }
}

/// The state of a row in words: "…" before the first poll, "out of reach" while the Mac is offline.
func stateLabel(for row: UpsRow) -> String {
    guard row.snapshot != nil else { return "…" }
    switch row.displayed {
    case .onMains: return tr("on mains")
    case .onBattery: return tr("on battery")
    case .lowBattery: return tr("low battery")
    case .noData: return tr("no data")
    case .refused: return tr("refused by the server")
    case .unreachable: return tr("unreachable")
    case nil: return tr("out of reach")
    }
}

/// The charge to show: none while the values are not current.
func chargeLabel(for row: UpsRow) -> String? {
    guard let displayed = row.displayed, ![.unreachable, .noData, .refused].contains(displayed) else { return nil }
    return row.snapshot?.chargePercent.map { "\($0) %" }
}

/// "Maison — 100 % — on mains"
func menuTitle(for row: UpsRow) -> String {
    [row.entry.name, chargeLabel(for: row), stateLabel(for: row)].compactMap { $0 }.joined(separator: " — ")
}
