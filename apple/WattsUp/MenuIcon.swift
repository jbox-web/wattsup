import AppKit

/// The menu bar icon of a look: a system symbol, as a template image.
func menuIcon(for look: MenuLook) -> NSImage? {
    // The first symbol this macOS knows; later names are fallbacks for older systems.
    let candidates: [String]
    switch look {
    case .allGood: candidates = ["bolt.batteryblock", "battery.100percent", "bolt"]
    case .attention: candidates = ["bolt.batteryblock.fill", "battery.25percent", "bolt.fill"]
    case .unreachable: candidates = ["bolt.slash", "exclamationmark.triangle"]
    case .empty: candidates = ["powerplug", "bolt"]
    case .waiting: candidates = ["ellipsis.circle", "bolt"]
    }
    for name in candidates {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel(for: look)) {
            image.isTemplate = true
            return image
        }
    }
    return nil
}

/// The tint that sets a troubled icon apart; nil keeps the menu bar's own colour.
func menuTint(for look: MenuLook) -> NSColor? {
    switch look {
    case .attention: return .systemOrange
    case .unreachable: return .systemRed
    case .allGood, .empty, .waiting: return nil
    }
}

func accessibilityLabel(for look: MenuLook) -> String {
    switch look {
    case .allGood: return tr("Watt's Up: all on mains")
    case .attention: return tr("Watt's Up: a UPS is on battery")
    case .unreachable: return tr("Watt's Up: a UPS is unreachable")
    case .empty: return tr("Watt's Up: no UPS configured")
    case .waiting: return tr("Watt's Up: waiting for the UPSes")
    }
}
