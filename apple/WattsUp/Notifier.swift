import Foundation
import WattsUpCore
import UserNotifications

struct NotificationText: Equatable {
    let title: String
    let body: String
}

/// What to tell the user about one event; the title is the name of the UPS.
func notificationText(for event: Event, entry: UpsEntry, snapshot: Snapshot?) -> NotificationText {
    let body: String
    switch event {
    case .onBattery:
        body = snapshot?.runtimeSeconds.map { tr("On battery — %@ left", runtimeLabel($0)) } ?? tr("On battery")
    case .lowBattery: body = tr("Battery low")
    case .backOnMains: body = tr("Back on mains power")
    case .unreachable: body = tr("Unreachable")
    case .reachableAgain: body = tr("Reachable again")
    case .noData: body = tr("The server has no fresh data from the UPS")
    case .refused:
        body = isKeychainFailure(snapshot)
            ? tr("The password cannot be read from the Keychain") : tr("The server refuses the request")
    case .replaceBattery: body = tr("Battery needs replacing")
    }
    return NotificationText(title: entry.name, body: body)
}

/// Power events are always worth telling; reachability only for the UPSes that ask for it.
func shouldNotify(_ event: Event, entry: UpsEntry, enabled: Bool) -> Bool {
    guard enabled else { return false }
    switch event {
    case .unreachable, .reachableAgain, .noData, .refused: return entry.notifyUnreachable
    case .onBattery, .lowBattery, .backOnMains, .replaceBattery: return true
    }
}

/// What to tell the user when they want notifications and macOS refuses them: once denied,
/// macOS does not ask again and files every notification without showing it.
func notificationsWarning(blockedByMacOS: Bool, enabled: Bool) -> String? {
    guard blockedByMacOS, enabled else { return nil }
    return tr("macOS does not let Watt's Up show notifications: allow them in System Settings.")
}

/// System Settings › Notifications › Watt's Up.
let notificationSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=fr.nicoladmin.wattsup")!

/// Posts local notifications. Does nothing when run outside the app bundle, where the
/// notification centre is not available.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?
    /// True when macOS refuses to show the app's notifications.
    @Published private(set) var blockedByMacOS = false

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Reads again what macOS allows: the user may have changed it in System Settings.
    func refresh() {
        center?.getNotificationSettings { [weak self] settings in
            let blocked = settings.authorizationStatus == .denied
            Task { @MainActor in self?.blockedByMacOS = blocked }
        }
    }

    /// Also shows the banner while one of the app's windows is in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func handle(_ events: [Event], entry: UpsEntry, snapshot: Snapshot?) {
        guard let center else { return }
        for event in events where shouldNotify(event, entry: entry, enabled: Preferences.notificationsEnabled) {
            let text = notificationText(for: event, entry: entry, snapshot: snapshot)
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
