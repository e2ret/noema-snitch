import NoemaShared
import SwiftUI

/// The Network Monitor: apps → domains → hosts with meters and rule toggles,
/// the traffic chart below and an optional inspector on the right.
struct MonitorView: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var helper: HelperClient
    @AppStorage("monitor.showChart") private var showChart = true
    @AppStorage("monitor.showInspector") private var showInspector = false
    @State private var search = ""
    @State private var filter: MonitorFilter = .all
    @State private var recentOnly = false
    @State private var expanded = Set<String>()
    @State private var showAll = Set<String>()
    @State private var selection: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SearchBar(text: $search, filter: $filter, recentOnly: $recentOnly)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                if !helper.isConnected {
                    HelperBanner()
                }
                list
                if showChart {
                    Divider()
                    TrafficPanel()
                }
            }
            .frame(minWidth: 360, idealWidth: 430, maxWidth: 460)

            Divider()
            GlobeView()
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

            if showInspector {
                Divider()
                InspectorView(selection: selection)
                    .frame(width: 320)
            }
        }
        .navigationTitle(Text("monitor.title"))
        .onAppear {
            if Demo.isEnabled {
                if let safari = model.sortedApps.first(where: { $0.name == "Safari" }) {
                    expanded.insert(safari.id)
                    selection = safari.id
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $showChart) {
                    Label("monitor.chart", systemImage: "chart.bar.xaxis")
                }
                .help(Text("monitor.chart"))
                Toggle(isOn: $showInspector) {
                    Label("monitor.inspector", systemImage: "sidebar.right")
                }
                .help(Text("monitor.inspector"))
            }
        }
    }

    // MARK: - Outline

    private enum Row: Identifiable {
        case app(AppNode)
        case domain(AppNode, DomainNode)
        case host(AppNode, DomainNode, HostNode)
        case more(AppNode, Int)

        var id: String {
            switch self {
            case .app(let a): a.id
            case .domain(_, let d): d.id
            case .host(_, _, let h): h.id
            case .more(let a, _): a.id + "|more"
            }
        }
    }

    private var rows: [Row] {
        _ = model.revision
        let cutoff = Date().addingTimeInterval(-300)
        var result: [Row] = []
        for app in model.sortedApps {
            if recentOnly && app.lastSeen < cutoff && app.active == 0 { continue }
            if !search.isEmpty && !matches(app) { continue }
            if !filter.includes(helper.ruleState(forApp: app.executablePath), denied: app.denied > 0) { continue }
            result.append(.app(app))
            guard expanded.contains(app.id) || !search.isEmpty else { continue }
            let domains = app.sortedDomains.filter { search.isEmpty || matches($0) }
            let limit = showAll.contains(app.id) ? domains.count : 4
            for domain in domains.prefix(limit) {
                result.append(.domain(app, domain))
                guard expanded.contains(domain.id) else { continue }
                for host in domain.sortedHosts {
                    result.append(.host(app, domain, host))
                }
            }
            if domains.count > limit {
                result.append(.more(app, domains.count - limit))
            }
        }
        return result
    }

    private var list: some View {
        List(rows, selection: $selection) { row in
            rowView(row)
                .listRowSeparator(.hidden)
        }
        .listStyle(.inset)
        .contentMargins(.top, 4, for: .scrollContent)
        .overlay {
            if model.apps.isEmpty {
                ContentUnavailableView("monitor.empty.title", systemImage: "network",
                                       description: Text("monitor.empty.description"))
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let now = Int(Date().timeIntervalSince1970)
        switch row {
        case .app(let app):
            OutlineRow(level: 0, expandable: !app.domains.isEmpty, expanded: binding(app.id)) {
                AppIcon(path: app.executablePath, size: 22)
                Text(verbatim: app.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if app.executablePath.hasPrefix("/System") || app.executablePath.hasPrefix("/usr") {
                    Text("monitor.system")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 3)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.6)))
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                ActivityMeter(points: app.series.points(seconds: 10, count: 5, now: now))
                RuleToggle(state: helper.ruleState(forApp: app.executablePath)) {
                    toggle(app: app)
                }
            }
        case .domain(let app, let domain):
            OutlineRow(level: 1, expandable: true, expanded: binding(domain.id)) {
                Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 16)
                Text(verbatim: domain.name).font(.system(size: 13)).lineLimit(1)
                if domain.denied > 0 {
                    Image(systemName: "xmark.octagon.fill").font(.caption).foregroundStyle(Palette.deny)
                }
            } trailing: {
                ActivityMeter(points: domain.series.points(seconds: 10, count: 5, now: now))
                RuleToggle(state: helper.ruleState(path: app.executablePath, host: domain.name, ip: domain.name)) {
                    toggle(app: app, pattern: isIP(domain.name) ? domain.name : "*." + domain.name,
                           current: helper.ruleState(path: app.executablePath, host: domain.name, ip: domain.name))
                }
            }
        case .host(let app, _, let host):
            OutlineRow(level: 2, expandable: false, expanded: .constant(false)) {
                Image(systemName: "server.rack").foregroundStyle(.secondary).frame(width: 16)
                Text(verbatim: host.name).font(.system(size: 12)).lineLimit(1)
                if !host.ports.isEmpty {
                    Text(verbatim: host.ports.sorted().map(String.init).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                ActivityMeter(points: host.series.points(seconds: 10, count: 5, now: now))
                let ip = host.ips.first ?? host.name
                RuleToggle(state: helper.ruleState(path: app.executablePath, host: host.hostname, ip: ip)) {
                    toggle(app: app, pattern: host.name,
                           current: helper.ruleState(path: app.executablePath, host: host.hostname, ip: ip))
                }
            }
        case .more(let app, let count):
            Button {
                showAll.insert(app.id)
            } label: {
                Text("monitor.more \(count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 46)
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func matches(_ app: AppNode) -> Bool {
        app.name.localizedCaseInsensitiveContains(search) || app.domains.values.contains(where: matches)
    }

    private func matches(_ domain: DomainNode) -> Bool {
        domain.name.localizedCaseInsensitiveContains(search)
            || domain.hosts.keys.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    private func isIP(_ s: String) -> Bool {
        s.contains(":") || s.allSatisfy { $0.isNumber || $0 == "." }
    }

    private func toggle(app: AppNode) {
        let next: RuleAction = helper.ruleState(forApp: app.executablePath) == .allow ? .deny : .allow
        helper.setRule(next, executablePath: app.executablePath, appName: app.name, hostPattern: nil)
    }

    private func toggle(app: AppNode, pattern: String, current: RuleState) {
        let next: RuleAction = current == .allow ? .deny : .allow
        helper.setRule(next, executablePath: app.executablePath, appName: app.name, hostPattern: pattern)
    }
}

enum MonitorFilter: String, CaseIterable, Identifiable {
    case all, allowed, denied, unapproved
    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .all: "filter.all"
        case .allowed: "filter.allowed"
        case .denied: "filter.denied"
        case .unapproved: "filter.unapproved"
        }
    }

    func includes(_ state: RuleState, denied: Bool) -> Bool {
        switch self {
        case .all: true
        case .allowed: state == .allow || state == .mixed
        case .denied: state == .deny || state == .mixed || denied
        case .unapproved: state == .none
        }
    }
}

private struct OutlineRow<Leading: View, Trailing: View>: View {
    let level: Int
    let expandable: Bool
    @Binding var expanded: Bool
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .opacity(expandable ? 1 : 0)
            }
            .buttonStyle(.plain)
            .disabled(!expandable)
            leading
            Spacer(minLength: 6)
            trailing
        }
        .padding(.leading, CGFloat(level) * 18)
        .padding(.vertical, level == 0 ? 3 : 1)
    }
}

private struct SearchBar: View {
    @Binding var text: String
    @Binding var filter: MonitorFilter
    @Binding var recentOnly: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("monitor.search", text: $text)
                .textFieldStyle(.plain)
            Divider().frame(height: 16)
            Menu {
                Picker("monitor.filter", selection: $filter) {
                    ForEach(MonitorFilter.allCases) { Text($0.titleKey).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle"
                                                 : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("monitor.filter"))
            Button {
                recentOnly.toggle()
            } label: {
                Image(systemName: recentOnly ? "clock.fill" : "clock")
            }
            .buttonStyle(.plain)
            .help(Text("monitor.recentOnly"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
    }
}

struct HelperBanner: View {
    @ObservedObject private var setup = HelperSetup.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("helper.notConnected").font(.callout.weight(.semibold))
                Text("helper.installHint").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(setup.state == .outdated ? "helper.update" : "helper.install") { setup.install() }
                        .controlSize(.small)
                        .disabled(setup.busy)
                    if setup.busy { ProgressView().controlSize(.mini) }
                }
                if let error = setup.error {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { setup.refresh() }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

/// Bottom of the monitor: sent/received totals, the chart and the time range.
struct TrafficPanel: View {
    @EnvironmentObject private var model: NetworkModel
    @AppStorage("monitor.rangeMinutes") private var rangeMinutes = 60
    var compact = false
    private static let ranges = [1, 5, 15, 60]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = Int(context.date.timeIntervalSince1970)
            let minutes = compact ? 5 : rangeMinutes
            let points = model.global.points(seconds: minutes * 60, count: compact ? 60 : 90, now: now)
            VStack(spacing: 6) {
                TrafficPills(sent: points.reduce(0) { $0 + $1.sent },
                             received: points.reduce(0) { $0 + $1.received })
                TrafficChart(points: points)
                    .frame(height: compact ? 60 : 110)
                if !compact {
                    HStack {
                        Button { step(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                            .disabled(rangeMinutes == Self.ranges.last)
                        Spacer()
                        Text("chart.lastMinutes \(rangeMinutes)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { step(1) } label: { Image(systemName: "plus.magnifyingglass") }
                            .disabled(rangeMinutes == Self.ranges.first)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)
        }
    }

    /// +1 zooms in (shorter range), -1 zooms out.
    private func step(_ direction: Int) {
        guard let i = Self.ranges.firstIndex(of: rangeMinutes) else {
            rangeMinutes = 60
            return
        }
        let next = min(max(i - direction, 0), Self.ranges.count - 1)
        rangeMinutes = Self.ranges[next]
    }
}
