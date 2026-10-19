import NoemaShared
import SwiftUI

/// The menu-bar window: filter switch, traffic, operating mode, recent activity.
struct StatusMenuView: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var helper: HelperClient

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("app.name").font(.headline)
                Spacer()
                if helper.isConnected {
                    Toggle("", isOn: Binding(get: { helper.settings.filteringEnabled },
                                             set: { value in helper.update { $0.filteringEnabled = value } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(Text("helper.filterToggle"))
                }
            }
            if !helper.isConnected {
                HelperBanner().padding(.horizontal, -8)
            }

            Button { MainSection.monitor.show() } label: {
                TrafficPanel(compact: true)
                    .padding(-8)
            }
            .buttonStyle(.plain)
            .help(Text("menu.showMonitor"))

            Divider()
            ForEach(FilterMode.allCases, id: \.self) { mode in
                Button {
                    helper.update { $0.mode = mode }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 16))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.titleKey).font(.system(size: 13, weight: .medium))
                            Text(mode.subtitleKey).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if helper.settings.mode == mode {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!helper.isConnected)
            }

            Divider()
            Text("menu.recentActivity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            let recent = model.recentApps.prefix(5)
            if recent.isEmpty {
                Text("menu.none").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(recent)) { app in
                HStack(spacing: 8) {
                    AppIcon(path: app.executablePath, size: 18)
                    Text(verbatim: app.name).lineLimit(1)
                    Spacer()
                    ActivityMeter(points: app.series.points(seconds: 10, count: 5, now: Int(Date().timeIntervalSince1970)))
                }
                .font(.system(size: 13))
            }

            Text("menu.recentlyDenied").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            let denied = recentlyDenied
            if denied.isEmpty {
                Text("menu.noneDenied").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(denied, id: \.id) { event in
                HStack(spacing: 8) {
                    AppIcon(path: event.executablePath, size: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: event.appName).lineLimit(1)
                        Text(verbatim: event.host ?? event.remoteIP).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(event.date, format: .relative(presentation: .numeric)).font(.caption2).foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
            }

            Divider()
            menuButton("menu.showMonitor") { MainSection.monitor.show() }
            menuButton("menu.showRules") { MainSection.rules.show() }
            menuButton("menu.settings") { MainSection.settings.show() }
            menuButton("menu.quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 320)
    }

    private var recentlyDenied: [TrafficEvent] {
        var seen = Set<String>()
        return helper.events.filter { e in
            e.action == .deny && seen.insert(e.executablePath + (e.host ?? e.remoteIP)).inserted
        }
        .prefix(3)
        .map { $0 }
    }

    private func menuButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

/// Lets AppKit code open SwiftUI windows (captured from the always-present menu bar icon).
@MainActor
enum WindowOpener {
    static var action: OpenWindowAction?

    static func open(_ id: String) {
        action?(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuBarIcon: View {
    @EnvironmentObject private var helper: HelperClient
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: icon)
            .onAppear { WindowOpener.action = openWindow }
    }

    private var icon: String {
        guard helper.isConnected, helper.settings.filteringEnabled else { return "network" }
        // Something is waiting for an Allow/Deny answer.
        if !helper.prompts.isEmpty { return "exclamationmark.shield.fill" }
        switch helper.settings.mode {
        case .alert: return "network.badge.shield.half.filled"
        case .silentAllow: return "checkmark.shield"
        case .silentDeny: return "xmark.shield"
        }
    }
}
