import NoemaShared
import Security
import SwiftUI

enum Palette {
    static let sent = Color(red: 0.86, green: 0.42, blue: 0.94)
    static let received = Color(red: 0.16, green: 0.55, blue: 0.96)
    static let allow = Color(red: 0.36, green: 0.73, blue: 0.16)
    static let deny = Color(red: 0.92, green: 0.22, blue: 0.20)
    static let mixed = Color(red: 0.16, green: 0.52, blue: 0.96)
    static let idle = Color.secondary.opacity(0.18)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct AppIcon: View {
    let path: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if path == "*" || path.isEmpty {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: AppIdentity.appPath(for: path) ?? path))
                    .resizable()
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Rule state toggle (green ✓ / red ✗ / gray / blue mixed)

enum RuleState {
    case allow, deny, mixed, none
}

extension HelperClient {
    func ruleState(forApp path: String) -> RuleState {
        let rules = rules.filter { $0.executablePath == path && $0.enabled }
        guard !rules.isEmpty else { return .none }
        let actions = Set(rules.map(\.action))
        if actions.count > 1 { return .mixed }
        return actions.first == .allow ? .allow : .deny
    }

    func ruleState(path: String, host: String?, ip: String) -> RuleState {
        guard let rule = RuleMatcher.match(rules, executablePath: path, host: host, ip: ip, port: 0) else {
            return .none
        }
        return rule.action == .allow ? .allow : .deny
    }
}

struct RuleToggle: View {
    let state: RuleState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(background)
                HStack(spacing: 0) {
                    switch state {
                    case .allow:
                        knob
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 18)
                    case .deny:
                        Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 18)
                        Spacer(minLength: 0)
                        knob
                    case .mixed:
                        Image(systemName: "xmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 18)
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 18)
                    case .none:
                        knob
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .frame(width: 18)
                    }
                }
                .padding(2)
            }
            .frame(width: 40, height: 22)
        }
        .buttonStyle(.plain)
        .help(Text(helpKey))
    }

    private var knob: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.white)
            .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
            .frame(width: 18, height: 18)
    }

    private var background: Color {
        switch state {
        case .allow: Palette.allow
        case .deny: Palette.deny
        case .mixed: Palette.mixed
        case .none: Palette.idle
        }
    }

    private var helpKey: LocalizedStringKey {
        switch state {
        case .allow: "toggle.allowed"
        case .deny: "toggle.denied"
        case .mixed: "toggle.mixed"
        case .none: "toggle.none"
        }
    }
}

// MARK: - Traffic

/// The small per-row meter: recent seconds as bars, sent on top, received below.
struct ActivityMeter: View {
    let points: [TrafficPoint]

    var body: some View {
        Canvas { ctx, size in
            let columns = points.count
            guard columns > 0 else { return }
            let gap: CGFloat = 1.5
            let w = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let half = (size.height - 1) / 2
            for (i, p) in points.enumerated() {
                let x = CGFloat(i) * (w + gap)
                let top = CGRect(x: x, y: 0, width: w, height: half)
                let bottom = CGRect(x: x, y: half + 1, width: w, height: half)
                ctx.fill(Path(top), with: .color(Palette.idle))
                ctx.fill(Path(bottom), with: .color(Palette.idle))
                let s = level(p.sent) * half
                let r = level(p.received) * half
                ctx.fill(Path(CGRect(x: x, y: half - s, width: w, height: s)), with: .color(Palette.sent))
                ctx.fill(Path(CGRect(x: x, y: half + 1, width: w, height: r)), with: .color(Palette.received))
            }
        }
        .frame(width: 30, height: 20)
    }

    /// 0…1 on a log scale: 100 B barely visible, ~10 MB/s full.
    private func level(_ bytes: Int64) -> CGFloat {
        guard bytes > 0 else { return 0 }
        return min(1, max(0.15, CGFloat(log10(Double(bytes)) - 1.5) / 5.5))
    }
}

/// Mirrored bar chart: sent (pink) above the axis, received (blue) below.
struct TrafficChart: View {
    let points: [TrafficPoint]

    var body: some View {
        Canvas { ctx, size in
            guard !points.isEmpty else { return }
            let peak = Double(max(points.map { max($0.sent, $0.received) }.max() ?? 1, 1))
            let gap: CGFloat = 1
            let w = max(1, (size.width - gap * CGFloat(points.count - 1)) / CGFloat(points.count))
            let mid = size.height * 0.5
            for (i, p) in points.enumerated() {
                let x = CGFloat(i) * (w + gap)
                ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Palette.idle.opacity(0.6)))
                let s = CGFloat(sqrt(Double(p.sent) / peak)) * (mid - 1)
                let r = CGFloat(sqrt(Double(p.received) / peak)) * (mid - 1)
                if p.sent > 0 {
                    ctx.fill(Path(CGRect(x: x, y: mid - max(s, 1.5), width: w, height: max(s, 1.5))), with: .color(Palette.sent))
                }
                if p.received > 0 {
                    ctx.fill(Path(CGRect(x: x, y: mid, width: w, height: max(r, 1.5))), with: .color(Palette.received))
                }
            }
        }
    }
}

struct TrafficPills: View {
    let sent: Int64
    let received: Int64

    var body: some View {
        HStack(spacing: 6) {
            pill(systemImage: "arrow.up.square.fill", title: "chart.sent", value: sent, color: Palette.sent)
            pill(systemImage: "arrow.down.square.fill", title: "chart.received", value: received, color: Palette.received)
        }
    }

    private func pill(systemImage: String, title: LocalizedStringKey, value: Int64, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(title).foregroundStyle(color)
            Spacer(minLength: 4)
            Text(verbatim: formatBytes(value)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Rules text

enum RuleText {
    static func describe(_ rule: Rule) -> String {
        let verb = rule.action == .allow ? "allow" : "deny"
        var text: String
        if let host = rule.host {
            if host.hasPrefix("*.") {
                text = String(format: localized("ruletext.\(verb).domain"), String(host.dropFirst(2)))
            } else {
                text = String(format: localized("ruletext.\(verb).host"), host)
            }
        } else {
            text = localized("ruletext.\(verb).any")
        }
        if let port = rule.port {
            text += String(format: localized("ruletext.port"), port)
        }
        return text
    }

    static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }
}

extension RuleLifetime {
    var titleKey: LocalizedStringKey {
        switch self {
        case .once: "lifetime.once"
        case .untilQuit: "lifetime.untilQuit"
        case .forever: "lifetime.forever"
        }
    }
}

extension FilterMode {
    var titleKey: LocalizedStringKey {
        switch self {
        case .alert: "mode.alert"
        case .silentAllow: "mode.silentAllow"
        case .silentDeny: "mode.silentDeny"
        }
    }

    var subtitleKey: LocalizedStringKey {
        switch self {
        case .alert: "mode.alert.subtitle"
        case .silentAllow: "mode.silentAllow.subtitle"
        case .silentDeny: "mode.silentDeny.subtitle"
        }
    }

    var systemImage: String {
        switch self {
        case .alert: "bubble.left.and.exclamationmark.bubble.right"
        case .silentAllow: "checkmark.shield"
        case .silentDeny: "xmark.shield"
        }
    }
}

extension Connection {
    var localizedState: String {
        guard let tcpState else { return "—" }
        return RuleText.localized("tcp.state.\(tcpState)")
    }
}

// MARK: - Code signature

enum CodeSigning {
    private static var cache: [String: String] = [:]

    /// "Apple", the developer's certificate name, or nil when unsigned / ad-hoc.
    @MainActor
    static func signer(of path: String) -> String? {
        if let cached = cache[path] { return cached.isEmpty ? nil : cached }
        var result: String?
        var code: SecStaticCode?
        if SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code {
            var info: CFDictionary?
            if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let dict = info as? [String: Any],
               let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
               let leaf = certs.first,
               let summary = SecCertificateCopySubjectSummary(leaf) as String? {
                result = summary.hasPrefix("Software Signing") || summary.hasPrefix("Apple") ? "Apple" : summary
            }
        }
        cache[path] = result ?? ""
        return result
    }
}
