import AppKit
import Combine
import WattsUpCore

/// "1 on battery · 1 on mains": how many UPSes are in each state, worst first.
func menuSummary(for rows: [UpsRow]) -> String {
    if rows.isEmpty { return tr("no UPS") }
    let polled = rows.filter { $0.snapshot != nil }
    if polled.isEmpty { return "…" }
    // The labels of `stateLabel`, in the order of gravity; "out of reach" (nil) comes last.
    let order: [State?] = [.lowBattery, .onBattery, .refused, .noData, .unreachable, .onMains, nil]
    return order.compactMap { state in
        let matching = polled.filter { $0.displayed == state }
        return matching.first.map { "\(matching.count) \(stateLabel(for: $0))" }
    }.joined(separator: " · ")
}

/// The colour of the dot in front of a UPS.
func dotColor(for row: UpsRow) -> NSColor {
    guard row.snapshot != nil else { return .tertiaryLabelColor }
    switch row.displayed {
    case .onMains: return .systemGreen
    case .onBattery: return .systemOrange
    case .lowBattery, .unreachable, .noData, .refused: return .systemRed
    case nil: return .tertiaryLabelColor
    }
}

/// The menu bar item: an icon for the worst state, a menu with one line per UPS.
@MainActor
final class StatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: Model
    private let openWindow: () -> Void
    private let openSettings: (SettingsView.Tab) -> Void
    private var subscriptions: Set<AnyCancellable> = []

    init(model: Model, openWindow: @escaping () -> Void, openSettings: @escaping (SettingsView.Tab) -> Void) {
        self.model = model
        self.openWindow = openWindow
        self.openSettings = openSettings
        super.init()
        // objectWillChange fires before the change: read the model on the next turn.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        refresh()
    }

    private func refresh() {
        let look = model.menuLook
        if let button = item.button {
            let icon = menuIcon(for: look)
            button.image = icon
            button.title = icon == nil ? "UPS" : ""
            button.contentTintColor = menuTint(for: look)
            button.toolTip = accessibilityLabel(for: look)
        }

        let menu = NSMenu()
        let header = NSMenuItem()
        header.attributedTitle = headerTitle()
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if let error = model.configError {
            menu.addItem(disabled(error))
        } else if model.rows.isEmpty {
            menu.addItem(action(tr("Add a UPS…"), #selector(showUpses), symbol: "plus"))
        }
        for row in model.rows {
            let line = action(menuTitle(for: row), #selector(showWindow), symbol: "circle.fill")
            line.image = dot(dotColor(for: row))
            menu.addItem(line)
        }
        menu.addItem(.separator())
        menu.addItem(action(tr("Open Watt's Up"), #selector(showWindow), symbol: "macwindow"))
        menu.addItem(action(tr("Manage UPSes…"), #selector(showUpses), key: ",", symbol: "list.bullet"))
        menu.addItem(action(tr("Settings…"), #selector(showSettings), symbol: "gearshape"))
        menu.addItem(action(tr("About Watt's Up"), #selector(showAbout), symbol: "info.circle"))
        menu.addItem(.separator())
        menu.addItem(action(tr("Quit Watt's Up"), #selector(quit), key: "q", symbol: "power"))
        item.menu = menu
    }

    /// The name in bold, then the summary in small grey type.
    private func headerTitle() -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: "Watt's Up", attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        title.append(NSAttributedString(
            string: "   \(menuSummary(for: model.rows))",
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
        return title
    }

    /// Every entry has an icon, so that the menu reads as one column.
    private func action(_ title: String, _ selector: Selector, key: String = "", symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    /// A small disc that keeps its colour in the menu (a template image would not).
    private func dot(_ color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        item.isEnabled = false
        return item
    }

    @objc private func showWindow() { openWindow() }

    @objc private func showUpses() { openSettings(.upses) }

    @objc private func showSettings() { openSettings(.general) }

    @objc private func showAbout() { openSettings(.about) }

    @objc private func quit() { NSApp.terminate(nil) }
}
