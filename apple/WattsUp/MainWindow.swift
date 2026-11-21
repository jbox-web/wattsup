import AppKit
import SwiftUI
import WattsUpCore

/// The headline values of a UPS, as text; nil where there is nothing current to show.
struct Summary: Equatable {
    let state: String
    let charge: String?
    let runtime: String?
    let load: String?
}

struct VariableRow: Identifiable, Equatable {
    let name: String
    let value: String

    var id: String { name }
}

/// Values are shown only when the last poll succeeded and the UPS is in reach.
private func currentSnapshot(of row: UpsRow) -> Snapshot? {
    guard row.displayed != nil, let snapshot = row.snapshot else { return nil }
    return snapshot.state == .unreachable || snapshot.state == .noData ? nil : snapshot
}

func summary(for row: UpsRow) -> Summary {
    let snapshot = currentSnapshot(of: row)
    let load = snapshot?.loadPercent.map { percent in
        snapshot?.loadWatts.map { "\(percent) % (\($0) W)" } ?? "\(percent) %"
    }
    return Summary(
        state: stateLabel(for: row),
        charge: snapshot?.chargePercent.map { "\($0) %" },
        runtime: snapshot?.runtimeSeconds.map(runtimeLabel),
        load: load)
}

/// "47 min", or "1 h 05 min" from one hour up.
func runtimeLabel(_ seconds: UInt32) -> String {
    let minutes = seconds / 60
    return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d min", minutes / 60, minutes % 60)
}

/// The variables of the last successful poll, sorted by name; the filter matches names and
/// values, whatever the case.
func variableRows(for row: UpsRow, filter: String) -> [VariableRow] {
    let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
    return (row.snapshot?.vars ?? [:])
        .filter { needle.isEmpty || $0.key.lowercased().contains(needle) || $0.value.lowercased().contains(needle) }
        .sorted { $0.key < $1.key }
        .map { VariableRow(name: $0.key, value: $0.value) }
}

func stateColor(for row: UpsRow) -> Color {
    guard row.snapshot != nil else { return .secondary }
    switch row.displayed {
    case .onMains: return .green
    case .onBattery: return .orange
    case .lowBattery, .unreachable, .noData: return .red
    case nil: return .secondary
    }
}

/// Owns the main window; closing it only hides it.
@MainActor
final class MainWindowController {
    private let window: NSWindow

    init(model: Model, openSettings: @escaping () -> Void) {
        let content = NSHostingController(rootView: MainView(model: model, openSettings: openSettings))
        window = NSWindow(contentViewController: content)
        window.title = "Watt's Up"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 860, height: 540))
        window.contentMinSize = NSSize(width: 640, height: 380)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MainWindow")
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct MainView: View {
    @ObservedObject var model: Model
    let openSettings: () -> Void
    @SwiftUI.State private var selection: String?

    private var selected: UpsRow? {
        model.rows.first { $0.id == selection } ?? model.rows.first
    }

    var body: some View {
        if let error = model.configError {
            ContentUnavailableView {
                Label("The configuration cannot be read", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            }
        } else if model.rows.isEmpty {
            ContentUnavailableView {
                Label("No UPS configured", systemImage: "powerplug")
            } description: {
                Text("Add the NUT server of a UPS to start watching it.")
            } actions: {
                Button("Open Settings…", action: openSettings)
            }
        } else {
            NavigationSplitView {
                List(model.rows, selection: $selection) { row in
                    UpsCell(row: row).tag(row.id)
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            } detail: {
                if let selected {
                    DetailView(row: selected).id(selected.id)
                }
            }
        }
    }
}

private struct UpsCell: View {
    let row: UpsRow

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(stateColor(for: row)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.entry.name).font(.headline)
                Text(row.snapshot?.model ?? row.entry.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(stateLabel(for: row)).font(.caption).foregroundStyle(stateColor(for: row))
            }
            Spacer()
            if let charge = summary(for: row).charge {
                Text(charge).font(.body.monospacedDigit())
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DetailView: View {
    let row: UpsRow
    @SwiftUI.State private var filter = ""

    var body: some View {
        let summary = summary(for: row)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.entry.name).font(.title2.bold())
                Text("\(row.entry.ups)@\(row.entry.host):\(String(row.entry.port))")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Tile(title: "State", value: summary.state, color: stateColor(for: row))
                Tile(title: "Charge", value: summary.charge)
                Tile(title: "Runtime", value: summary.runtime)
                Tile(title: "Load", value: summary.load)
            }
            if let flags = row.snapshot?.extraFlags, !flags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(flags, id: \.self) { flag in
                        Text(flagLabel(flag)).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.orange.opacity(0.2), in: Capsule())
                    }
                }
            }
            if let error = row.snapshot?.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
            }
            let variables = variableRows(for: row, filter: filter)
            Table(variables) {
                TableColumn("Variable") { Text($0.name).textSelection(.enabled) }
                TableColumn("Value") { Text($0.value).textSelection(.enabled) }
            }
            .searchable(text: $filter, placement: .toolbar, prompt: "Filter variables")
            if let lastUpdate = row.lastUpdate {
                Text("Last poll: \(lastUpdate.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

private struct Tile: View {
    let title: LocalizedStringKey
    let value: String?
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "–").font(.title3.monospacedDigit()).foregroundStyle(value == nil ? .secondary : color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The NUT status flags worth a word; unknown ones are shown as they are.
func flagLabel(_ flag: String) -> String {
    switch flag {
    case "RB": return tr("Replace battery")
    case "FSD": return tr("Forced shutdown")
    case "OFF": return tr("Off")
    case "BYPASS": return tr("Bypass")
    case "OVER": return tr("Overloaded")
    case "TRIM": return tr("Trimming voltage")
    case "BOOST": return tr("Boosting voltage")
    case "CAL": return tr("Calibrating")
    default: return flag
    }
}
