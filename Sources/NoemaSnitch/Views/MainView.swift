import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case monitor, rules, settings
    var id: String { rawValue }

    static let storageKey = "main.section"

    var titleKey: LocalizedStringKey {
        switch self {
        case .monitor: "section.monitor"
        case .rules: "section.rules"
        case .settings: "section.settings"
        }
    }

    var systemImage: String {
        switch self {
        case .monitor: "network"
        case .rules: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }

    /// Switches the single window to this section and brings it forward.
    @MainActor
    func show() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
        WindowOpener.open("main")
    }
}

/// The only window: Monitor, Rules and Settings swap in place via the toolbar switcher.
struct MainView: View {
    @AppStorage(MainSection.storageKey) private var section: MainSection = .monitor

    var body: some View {
        Group {
            switch section {
            case .monitor:
                MonitorView()
            case .rules:
                RulesWindowView()
            case .settings:
                ScrollView {
                    SettingsView()
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                }
                .navigationTitle(Text("section.settings"))
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $section) {
                    ForEach(MainSection.allCases) { s in
                        Label(s.titleKey, systemImage: s.systemImage).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .fixedSize()
            }
        }
    }
}
