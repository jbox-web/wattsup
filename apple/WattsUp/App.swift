import AppKit
import WattsUpCore

@main
enum Main {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only, also when run outside the bundle (swift run): no Dock icon.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let network = NetworkWatch()
    private let publisher = Publisher()
    private var model: Model!
    private var statusMenu: StatusMenu!
    private var mainWindow: MainWindowController!
    private var settingsWindow: SettingsWindowController!
    private var notifier: Notifier!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let network = self.network
        let publisher = self.publisher
        model = Model(
            poller: CorePoller(), configPath: Self.configPath, networkOnline: { network.isOnline },
            secrets: Keychain(),
            publish: { name, snapshot in publisher.set(name: name, snapshot: snapshot) })
        let settings = SettingsWindowController(model: model)
        settingsWindow = settings
        let window = MainWindowController(model: model, openSettings: { settings.show(.upses) })
        mainWindow = window
        statusMenu = StatusMenu(model: model, openWindow: { window.show() }, openSettings: { settings.show($0) })
        let notifier = Notifier()
        self.notifier = notifier
        model.onEvents = { [weak model] entry, events in
            let snapshot = model?.rows.first { $0.entry.name == entry.name }?.snapshot
            notifier.handle(events, entry: entry, snapshot: snapshot)
        }
        model.start()
    }

    /// `WATTSUP_CONFIG` points a development run at another file than the user's.
    private static var configPath: String {
        ProcessInfo.processInfo.environment["WATTSUP_CONFIG"] ?? defaultConfigPath()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
