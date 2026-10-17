import NoemaShared
import SwiftUI

enum RulesFilter: String, CaseIterable, Identifiable {
    case all, allowed, denied, temporary, recent
    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .all: "rules.filter.all"
        case .allowed: "rules.filter.allowed"
        case .denied: "rules.filter.denied"
        case .temporary: "rules.filter.temporary"
        case .recent: "rules.filter.recent"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "list.bullet.rectangle.fill"
        case .allowed: "checkmark.square.fill"
        case .denied: "xmark.square.fill"
        case .temporary: "hourglass"
        case .recent: "clock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .all: .purple
        case .allowed: Palette.allow
        case .denied: Palette.deny
        case .temporary: .green
        case .recent: .orange
        }
    }

    func includes(_ rule: Rule) -> Bool {
        switch self {
        case .all: true
        case .allowed: rule.action == .allow
        case .denied: rule.action == .deny
        case .temporary: rule.lifetime != .forever
        case .recent: rule.created > Date().addingTimeInterval(-7 * 24 * 3600)
        }
    }
}

/// Rules window: filter sidebar, rules grouped by process, rule inspector.
struct RulesWindowView: View {
    @EnvironmentObject private var helper: HelperClient
    @State private var filter: RulesFilter? = .all
    @State private var selection: Rule.ID?
    @State private var search = ""

    private struct Group: Identifiable {
        let id: String
        let name: String
        let rules: [Rule]
    }

    private var filtered: [Rule] {
        helper.rules.filter { rule in
            (filter ?? .all).includes(rule)
                && (search.isEmpty
                    || rule.appName.localizedCaseInsensitiveContains(search)
                    || (rule.host ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    private var groups: [Group] {
        let byProcess = Dictionary(grouping: filtered, by: \.executablePath)
        return byProcess.map { path, rules in
            Group(id: path,
                  name: path == "*" ? RuleText.localized("rule.anyProcess") : (rules.first?.appName ?? path),
                  rules: rules.sorted { RuleText.describe($0) < RuleText.describe($1) })
        }
        .sorted { a, b in
            if a.id == "*" { return true }
            if b.id == "*" { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $filter) {
                Section("rules.section") {
                    ForEach(RulesFilter.allCases) { f in
                        Label {
                            Text(f.titleKey)
                        } icon: {
                            Image(systemName: f.systemImage).foregroundStyle(f.tint)
                        }
                        .badge(helper.rules.filter(f.includes).count)
                        .tag(f)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 210)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    Divider()
                    columnHeader
                    Divider()
                    table
                }
                Divider()
                RuleInspectorView(rule: helper.rules.first { $0.id == selection })
                    .frame(width: 300)
            }
        }
    }

    private var header: some View {
        let f = filter ?? .all
        return HStack(spacing: 12) {
            Image(systemName: f.systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(f.tint, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 0) {
                Text(f.titleKey).font(.system(size: 17, weight: .bold))
                Text("rules.count \(filtered.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !helper.isConnected {
                Label("helper.notConnected", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("rules.search", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 220)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("rules.column.process").frame(width: 230, alignment: .leading)
            Text("rules.column.rule")
            Spacer()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(groups) { group in
                    HStack(alignment: .top, spacing: 0) {
                        HStack(spacing: 8) {
                            AppIcon(path: group.id, size: 18)
                            Text(verbatim: group.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .frame(width: 230, alignment: .leading)
                        .background(groupSelected(group) ? Color.accentColor : .clear)
                        .foregroundStyle(groupSelected(group) ? .white : .primary)

                        VStack(spacing: 0) {
                            ForEach(group.rules) { rule in
                                ruleRow(rule)
                            }
                        }
                    }
                    Divider()
                }
            }
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("rules.empty.title", systemImage: "list.bullet.rectangle",
                                       description: Text("rules.empty.description"))
            }
        }
    }

    private func groupSelected(_ group: Group) -> Bool {
        group.rules.contains { $0.id == selection }
    }

    private func ruleRow(_ rule: Rule) -> some View {
        let selected = rule.id == selection
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { value in
                var copy = rule
                copy.enabled = value
                helper.upsert(copy)
            }))
            .labelsHidden()
            .toggleStyle(.checkbox)
            Image(systemName: rule.action == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(selected ? .white : (rule.action == .allow ? Palette.allow : Palette.deny))
            Image(systemName: "arrow.right.square")
                .foregroundStyle(selected ? .white : .secondary)
                .font(.system(size: 11))
            Text(verbatim: RuleText.describe(rule))
                .lineLimit(1)
                .opacity(rule.enabled ? 1 : 0.5)
            Spacer(minLength: 6)
            if rule.lifetime != .forever {
                Text(rule.lifetime.titleKey)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(selected ? .white : .secondary.opacity(0.6)))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor : .clear)
        .foregroundStyle(selected ? .white : .primary)
        .contentShape(Rectangle())
        .onTapGesture { selection = rule.id }
        .contextMenu {
            Button("action.toggleRule") {
                var copy = rule
                copy.action = rule.action == .allow ? .deny : .allow
                helper.upsert(copy)
            }
            Button("action.delete", role: .destructive) { helper.deleteRules([rule.id]) }
        }
    }
}

struct RuleInspectorView: View {
    @EnvironmentObject private var helper: HelperClient
    let rule: Rule?

    var body: some View {
        ScrollView {
            if let rule {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        AppIcon(path: rule.executablePath, size: 44)
                        Text(verbatim: rule.executablePath == "*" ? RuleText.localized("rule.anyProcess") : rule.appName)
                            .font(.title2.bold())
                            .lineLimit(2)
                    }
                    let color = rule.action == .allow ? Palette.allow : Palette.deny
                    Text(verbatim: RuleText.describe(rule))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))

                    Picker("rules.inspector.action", selection: Binding(get: { rule.action }, set: { value in
                        var copy = rule
                        copy.action = value
                        helper.upsert(copy)
                    })) {
                        Text("rule.allow").tag(RuleAction.allow)
                        Text("rule.deny").tag(RuleAction.deny)
                    }
                    .pickerStyle(.segmented)

                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                        row("inspector.path", rule.executablePath == "*" ? RuleText.localized("rule.anyProcess") : rule.executablePath)
                        row("inspector.host", rule.host ?? RuleText.localized("rule.anyHost"))
                        row("inspector.ports", rule.port.map(String.init) ?? RuleText.localized("rule.anyPort"))
                        GridRow {
                            Text("column.lifetime").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(rule.lifetime.titleKey)
                        }
                        GridRow {
                            Text("column.created").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(rule.created, format: .dateTime.day().month().year().hour().minute())
                        }
                    }
                    .font(.callout)

                    Button("action.delete", role: .destructive) { helper.deleteRules([rule.id]) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!helper.isConnected)
            } else {
                Text("rules.inspector.nothing")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }
        }
        .background(.background)
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(verbatim: value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
