import AppKit
import Network

/// Tells whether a failed poll can be blamed on the site: not when the Mac itself has no
/// network path, and not in the seconds after it wakes up, while interfaces come back.
final class NetworkWatch: @unchecked Sendable {
    static let settleSecondsAfterWake: TimeInterval = 30

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var pathSatisfied = true
    private var wokeAt: Date?
    private var wakeObserver: NSObjectProtocol?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.pathSatisfied = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "fr.nicoladmin.wattsup.network"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.wokeAt = Date()
            self.lock.unlock()
        }
    }

    deinit {
        monitor.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.isOnline(pathSatisfied: pathSatisfied, secondsSinceWake: wokeAt.map { Date().timeIntervalSince($0) })
    }

    static func isOnline(pathSatisfied: Bool, secondsSinceWake: TimeInterval?) -> Bool {
        guard pathSatisfied else { return false }
        guard let secondsSinceWake else { return true }
        return secondsSinceWake > settleSecondsAfterWake
    }
}
