// Updates with Sparkle: the latest GitHub Release's appcast.xml, checked daily; a new
// version is offered, and installed (the .pkg, administrator password asked) only when the
// user accepts.

import AppKit
import Sparkle

@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    /// Only the assembled app can be replaced, and only once it names a feed and the key its
    /// updates are signed with: `swift run` and the tests have neither. `WATTSUP_NO_UPDATES`
    /// keeps an assembled app off the feed (apple/launch-check.sh).
    nonisolated static func canUpdate(
        _ bundle: Bundle, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let info = bundle.infoDictionary ?? [:]
        let key = info["SUPublicEDKey"] as? String ?? ""
        let feed = info["SUFeedURL"] as? String ?? ""
        return bundle.bundleURL.pathExtension == "app" && !key.isEmpty && !feed.isEmpty
            && environment["WATTSUP_NO_UPDATES"] == nil
    }

    // No gentle reminders: they would leave a menu bar app's update alert behind the other
    // apps' windows, with nothing else to signal it. Sparkle brings its alert to the front.
    func start() {
        guard Self.canUpdate(Bundle.main), controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var available: Bool { controller != nil }

    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    // The package's installer starts once the administrator password is given. When that
    // dialog closes, macOS gives the focus back to the app active before, never to a menu
    // bar app: the window that then offers to install and relaunch would stay behind. It
    // floats above the other apps' windows until it closes.
    nonisolated func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated {
            let sparkle = Bundle(for: SPUStandardUpdaterController.self)
            for window in NSApp.windows where window.isVisible
                && window.windowController.map({ Bundle(for: type(of: $0)) == sparkle }) == true {
                window.level = .floating
                window.orderFrontRegardless()
            }
            NSApp.activate()
        }
    }
}
