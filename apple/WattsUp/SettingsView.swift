import AppKit
import ServiceManagement
import SwiftUI
import WattsUpCore

/// What the app remembers besides the configuration file.
enum Preferences {
    static let notificationsKey = "notificationsEnabled"

    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: notificationsKey) as? Bool ?? true
    }
}

/// Owns the settings window; closing it only hides it.
@MainActor
final class SettingsWindowController {
    private let window: NSWindow
    private let selection = SettingsView.Selection()

    init(model: Model) {
        let content = NSHostingController(rootView: SettingsView(model: model, selection: selection))
        window = NSWindow(contentViewController: content)
        window.title = tr("Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    /// Shows the window on a tab, switching an already open window to it.
    func show(_ tab: SettingsView.Tab) {
        selection.tab = tab
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    enum Tab: Hashable { case upses, general, about }

    /// The tab shown; set from outside to switch an open window to it.
    final class Selection: ObservableObject {
        @Published var tab: Tab = .upses
    }

    @ObservedObject var model: Model
    @ObservedObject var selection: Selection

    var body: some View {
        TabView(selection: $selection.tab) {
            UpsSettings(model: model).tabItem { Label("UPSes", systemImage: "bolt.batteryblock") }.tag(Tab.upses)
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            AboutView().tabItem { Label("About", systemImage: "info.circle") }.tag(Tab.about)
        }
        .padding(20)
        // A fixed size: grouped forms have no height of their own, and the first tab would
        // open collapsed.
        .frame(width: 560, height: 480)
    }
}

/// "0.1.0 (2611181007)": the version, and the build when there is one.
func aboutVersion(_ info: [String: Any]) -> String {
    guard let short = info["CFBundleShortVersionString"] as? String else { return "–" }
    guard let build = info["CFBundleVersion"] as? String else { return short }
    return "\(short) (\(build))"
}

/// Name, version and licence.
private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(verbatim: "Watt's Up").font(.title.bold())
            Text(tr("Version %@", aboutVersion(Bundle.main.infoDictionary ?? [:])))
                .foregroundStyle(.secondary).textSelection(.enabled)
            Text("Watches the UPSes served by NUT servers: menu bar, Batteries widget and notifications.")
                .multilineTextAlignment(.center)
            Link("Source code on GitHub", destination: URL(string: "https://github.com/jbox-web/wattsup")!)
                .font(.callout)
            Divider().frame(width: 300)
            Text(verbatim: "© 2026 Nicolas Rodriguez")
            Text("Free software: use, change and share it under the MIT license.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Link("MIT License", destination: URL(string: "https://opensource.org/license/mit")!)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: Model
    @AppStorage(Preferences.notificationsKey) private var notifications = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var interval = 30
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Stepper(value: $interval, in: 5...3600, step: 5) {
                    Text("Poll every \(interval) seconds")
                }
                .disabled(model.configError != nil)
                .onChange(of: interval) { _, seconds in
                    // Showing the current value is not a change to save.
                    guard UInt32(seconds) != model.pollIntervalSeconds else { return }
                    attempt { try model.setPollInterval(UInt32(seconds)) }
                }
                Toggle("Notifications", isOn: $notifications)
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { interval = Int(model.pollIntervalSeconds) }
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
            error = nil
        } catch let failure {
            error = failure.localizedDescription
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        attempt {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct UpsSettings: View {
    @ObservedObject var model: Model
    @State private var editing: Editing?
    @State private var removing: UpsEntry?
    @State private var error: String?

    /// The UPS being added (nil) or edited.
    private struct Editing: Identifiable {
        let original: UpsEntry?
        var id: String { original?.name ?? "" }
    }

    var body: some View {
        Form {
            Section {
                if model.rows.isEmpty {
                    Text("No UPS yet.").foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.entry.name)
                            Text("\(row.entry.ups)@\(row.entry.host):\(String(row.entry.port))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editing = Editing(original: row.entry) }
                        Button("Remove", role: .destructive) { removing = row.entry }
                    }
                }
                Button("Add a UPS…") { editing = Editing(original: nil) }
            }
            .disabled(model.configError != nil)
            if let configError = model.configError {
                Section {
                    Label(configError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            Section {
                Text("Configuration: \(model.configPath)").font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { editing in
            UpsEditor(model: model, original: editing.original)
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let name = removing?.name {
                    do {
                        try model.remove(name)
                        error = nil
                    } catch let failure {
                        error = failure.localizedDescription
                    }
                }
                removing = nil
            }
        } message: {
            Text("Its entry in the configuration and its password in the Keychain are deleted.")
        }
    }
}

/// The sheet that adds or edits one UPS.
private struct UpsEditor: View {
    @ObservedObject var model: Model
    let original: UpsEntry?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "3493"
    @State private var ups = ""
    @State private var username = ""
    @State private var password = ""
    @State private var publish = true
    @State private var notifyUnreachable = true
    @State private var offered: [UpsName] = []
    @State private var testing = false
    @State private var message: String?
    @State private var failed = false

    private var entry: UpsEntry? {
        guard let port = UInt16(port.trimmingCharacters(in: .whitespaces)), port > 0 else { return nil }
        let username = username.trimmingCharacters(in: .whitespaces)
        return UpsEntry(
            name: name.trimmingCharacters(in: .whitespaces), host: host.trimmingCharacters(in: .whitespaces),
            port: port, ups: ups.trimmingCharacters(in: .whitespaces), publish: publish,
            notifyUnreachable: notifyUnreachable, username: username.isEmpty ? nil : username)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Server") {
                    TextField("Name", text: $name, prompt: Text("Home"))
                    TextField("Host", text: $host, prompt: Text("nas.example or 192.0.2.10"))
                    TextField("Port", text: $port)
                    HStack {
                        Button(testing ? tr("Testing…") : tr("Test connection")) { test() }
                            .disabled(testing || host.trimmingCharacters(in: .whitespaces).isEmpty || UInt16(port) == nil)
                        if let message {
                            Text(message).font(.caption).foregroundStyle(failed ? .red : .secondary).lineLimit(2)
                        }
                    }
                    if offered.isEmpty {
                        TextField("UPS name on the server", text: $ups, prompt: Text("ups"))
                    } else {
                        Picker("UPS name on the server", selection: $ups) {
                            ForEach(offered, id: \.name) { Text("\($0.name) — \($0.description)").tag($0.name) }
                        }
                    }
                }
                Section("Authentication (optional)") {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password, prompt: Text(original?.username == nil ? "" : tr("unchanged")))
                }
                Section {
                    Toggle("Show in the Batteries widget", isOn: $publish)
                    Toggle("Notify when unreachable", isOn: $notifyUnreachable)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(original == nil ? tr("Add") : tr("Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(entry == nil)
            }
            .padding()
        }
        .frame(width: 460, height: 520)
        .onAppear(perform: load)
    }

    private func load() {
        guard let original else { return }
        name = original.name
        host = original.host
        port = String(original.port)
        ups = original.ups
        username = original.username ?? ""
        publish = original.publish
        notifyUnreachable = original.notifyUnreachable
    }

    private func test() {
        guard let port = UInt16(port.trimmingCharacters(in: .whitespaces)) else { return }
        testing = true
        message = nil
        Task {
            let result = await model.testConnection(host: host.trimmingCharacters(in: .whitespaces), port: port)
            testing = false
            switch result {
            case .success(let names):
                offered = names
                failed = names.isEmpty
                message = names.isEmpty ? tr("The server offers no UPS.") : tr("Connected: %d UPS found.", names.count)
                if !names.contains(where: { $0.name == ups }), let first = names.first { ups = first.name }
            case .failure(let failure):
                offered = []
                failed = true
                message = failure.reason
            }
        }
    }

    private func save() {
        guard let entry else { return }
        do {
            let password = password.isEmpty ? nil : password
            if let original {
                try model.update(original.name, with: entry, password: password)
            } else {
                try model.add(entry, password: password)
            }
            dismiss()
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }
}
