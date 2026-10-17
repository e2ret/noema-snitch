import NoemaShared
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var monitor: ConnectionMonitor
    @EnvironmentObject private var helper: HelperClient
    @AppStorage("refreshInterval") private var interval: Double = 2
    @AppStorage("resolveHostnames") private var resolveHostnames = true
    @ObservedObject private var setup = HelperSetup.shared
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            Section("helper.section") {
                LabeledContent("helper.status") {
                    HelperStatusLabel(connected: helper.isConnected, state: setup.state)
                }
                HStack {
                    if setup.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    if setup.state != .installed || !helper.isConnected {
                        Button(setup.state == .outdated ? "helper.update" : "helper.install") { setup.install() }
                    }
                    if setup.state != .notInstalled {
                        Button("helper.uninstall", role: .destructive) { confirmUninstall = true }
                    }
                }
                .disabled(setup.busy)
                if let error = setup.error {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("settings.launchAtLogin", isOn: Binding(get: { setup.opensAtLogin },
                                                              set: { setup.setOpensAtLogin($0) }))
            }
            .confirmationDialog("helper.uninstall.confirm", isPresented: $confirmUninstall) {
                Button("helper.uninstall", role: .destructive) { setup.uninstall() }
            }

            Section("settings.filtering") {
                Toggle("helper.filterToggle", isOn: setting(\.filteringEnabled))
                Picker("settings.mode", selection: setting(\.mode)) {
                    ForEach(FilterMode.allCases, id: \.self) { Text($0.titleKey).tag($0) }
                }
                Toggle("settings.blockQUIC", isOn: setting(\.blockQUIC))
                Picker("settings.promptTimeout", selection: setting(\.promptTimeout)) {
                    ForEach([15, 30, 60, 120], id: \.self) { Text("settings.seconds \($0)").tag($0) }
                }
                Picker("settings.withoutUI", selection: setting(\.actionWithoutUI)) {
                    Text("rule.allow").tag(RuleAction.allow)
                    Text("rule.deny").tag(RuleAction.deny)
                }
            }
            .disabled(!helper.isConnected)

            Section("settings.monitor") {
                Picker("settings.interval", selection: $interval) {
                    Text("settings.seconds \(1)").tag(1.0)
                    Text("settings.seconds \(2)").tag(2.0)
                    Text("settings.seconds \(5)").tag(5.0)
                }
                .onChange(of: interval) { monitor.restart() }
                Toggle("settings.resolveHostnames", isOn: $resolveHostnames)
            }

            Section {
                LabeledContent("settings.language") {
                    Text("settings.languageSystem").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { setup.refresh() }
        .frame(width: 460)
        .fixedSize()
    }

    private func setting<T>(_ keyPath: WritableKeyPath<HelperSettings, T>) -> Binding<T> {
        Binding(get: { helper.settings[keyPath: keyPath] },
                set: { value in helper.update { $0[keyPath: keyPath] = value } })
    }
}

struct HelperStatusLabel: View {
    let connected: Bool
    let state: HelperSetup.State

    var body: some View {
        switch (state, connected) {
        case (.notInstalled, _):
            Label("helper.status.notInstalled", systemImage: "xmark.circle.fill").foregroundStyle(.secondary)
        case (.outdated, _):
            Label("helper.status.outdated", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange)
        case (.installed, true):
            Label("helper.status.running", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.allow)
        case (.installed, false):
            Label("helper.status.notResponding", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
