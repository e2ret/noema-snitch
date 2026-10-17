import NoemaShared
import SwiftUI

/// Right-hand panel of the Network Monitor for the selected app, domain or host.
struct InspectorView: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var helper: HelperClient
    let selection: String?

    var body: some View {
        let _ = model.revision
        ScrollView {
            if let (app, domain, host) = resolve() {
                VStack(alignment: .leading, spacing: 14) {
                    header(app: app, domain: domain, host: host)
                    ruleBox(app: app, domain: domain, host: host)
                    details(app: app, domain: domain, host: host)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("inspector.nothing")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }
        }
        .background(.background)
    }

    private func resolve() -> (AppNode, DomainNode?, HostNode?)? {
        guard let selection else { return nil }
        let parts = selection.components(separatedBy: "|")
        guard let app = model.app(parts[0]) else { return nil }
        let domain = parts.count > 1 ? app.domains[parts[1]] : nil
        let host = parts.count > 2 ? domain?.hosts[parts[2]] : nil
        return (app, domain, host)
    }

    private func header(app: AppNode, domain: DomainNode?, host: HostNode?) -> some View {
        HStack(spacing: 12) {
            AppIcon(path: app.executablePath, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: app.name).font(.title2.bold()).lineLimit(1)
                if let target = host?.name ?? domain?.name {
                    Text(verbatim: target).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func ruleBox(app: AppNode, domain: DomainNode?, host: HostNode?) -> some View {
        let rule = matchingRule(app: app, domain: domain, host: host)
        // For the app itself, rules for individual domains count too.
        let appRules = domain == nil
            ? helper.rules.filter { $0.executablePath == app.executablePath && $0.id != rule?.id }
            : []
        let (text, color): (String, Color) = {
            if let rule { return (RuleText.describe(rule), rule.action == .allow ? Palette.allow : Palette.deny) }
            if !appRules.isEmpty {
                return (String(format: RuleText.localized("inspector.someRules"), appRules.count), Palette.mixed)
            }
            return (RuleText.localized("inspector.noRule"), .secondary)
        }()
        HStack(spacing: 8) {
            Image(systemName: rule.map { $0.action == .allow ? "checkmark.circle.fill" : "xmark.circle.fill" }
                  ?? (appRules.isEmpty ? "questionmark.circle" : "list.bullet.circle.fill"))
                .foregroundStyle(color)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))

        if !appRules.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(appRules) { r in
                    HStack(spacing: 6) {
                        Image(systemName: r.action == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r.action == .allow ? Palette.allow : Palette.deny)
                        Text(verbatim: RuleText.describe(r)).lineLimit(2)
                        Spacer(minLength: 4)
                        Button {
                            helper.deleteRules([r.id])
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("inspector.removeRule"))
                    }
                    .font(.callout)
                }
            }
        }

        HStack {
            Button("rule.allow") { set(.allow, app: app, domain: domain, host: host) }
            Button("rule.deny") { set(.deny, app: app, domain: domain, host: host) }
            if let rule {
                Spacer()
                Button("inspector.removeRule", role: .destructive) { helper.deleteRules([rule.id]) }
            }
        }
        .controlSize(.small)
        .disabled(!helper.isConnected)
    }

    private func details(app: AppNode, domain: DomainNode?, host: HostNode?) -> some View {
        let node: TrafficNode = host ?? domain ?? app
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            if let host {
                if let name = host.hostname { row("inspector.host", name) }
                row("inspector.ip", host.ips.sorted().joined(separator: "\n"))
                row("inspector.ports", host.ports.sorted().map(String.init).joined(separator: ", "))
            } else if let domain {
                row("inspector.hosts", String(domain.hosts.count))
            } else {
                row("inspector.domains", String(app.domains.count))
                row("inspector.path", app.executablePath)
                row("inspector.signedBy", CodeSigning.signer(of: app.executablePath) ?? RuleText.localized("inspector.unsigned"))
                if app.pid > 0 { row("inspector.pid", String(app.pid)) }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            row("inspector.active", String(node.active))
            row("chart.sent", formatBytes(node.totalSent))
            row("chart.received", formatBytes(node.totalReceived))
            if node.denied > 0 { row("inspector.denied", String(node.denied)) }
            if node.lastSeen > .distantPast {
                GridRow {
                    Text("inspector.lastSeen").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(node.lastSeen, format: .relative(presentation: .named))
                }
            }
        }
        .font(.callout)
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(verbatim: value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pattern(domain: DomainNode?, host: HostNode?) -> String? {
        if let host { return host.name }
        if let domain {
            let isIP = domain.name.contains(":") || domain.name.allSatisfy { $0.isNumber || $0 == "." }
            return isIP ? domain.name : "*." + domain.name
        }
        return nil
    }

    private func matchingRule(app: AppNode, domain: DomainNode?, host: HostNode?) -> Rule? {
        let name = host?.hostname ?? domain?.name
        let ip = host?.ips.first ?? domain?.name ?? ""
        if domain == nil {
            return helper.rules.first { $0.executablePath == app.executablePath && $0.host == nil && $0.port == nil }
        }
        return RuleMatcher.match(helper.rules, executablePath: app.executablePath, host: name, ip: ip, port: 0)
    }

    private func set(_ action: RuleAction, app: AppNode, domain: DomainNode?, host: HostNode?) {
        helper.setRule(action, executablePath: app.executablePath, appName: app.name,
                       hostPattern: pattern(domain: domain, host: host))
    }
}
