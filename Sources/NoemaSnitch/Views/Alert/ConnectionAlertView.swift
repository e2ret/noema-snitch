import NoemaShared
import SwiftUI

/// The Allow/Deny alert, laid out like Little Snitch's connection alert:
/// gray header with icon and app name, lifetime popup, "Any connection" /
/// "Only …" choice, details disclosure, Deny… and a green Allow.
struct ConnectionAlertView: View {
    @EnvironmentObject private var helper: HelperClient
    @State private var lifetime: RuleLifetime = .forever
    @State private var anyConnection = false
    @State private var scope: Scope = .host("")
    @State private var expanded = false
    @State private var remaining = 0
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum Scope: Hashable {
        case domain(String)
        case host(String)
        case ip(String)

        var pattern: String {
            switch self {
            case .domain(let d): "*." + d
            case .host(let h): h
            case .ip(let ip): ip
            }
        }
    }

    var body: some View {
        if let prompt = helper.prompts.first {
            VStack(spacing: 0) {
                header(prompt)
                Divider()
                options(prompt)
                if expanded {
                    details(prompt)
                }
                footer(prompt)
            }
            .frame(width: 560)
            .onAppear { reset(for: prompt) }
            .onChange(of: prompt.id) { reset(for: prompt) }
            .onReceive(tick) { _ in remaining = max(0, Int(prompt.deadline.timeIntervalSinceNow)) }
        }
    }

    private func header(_ prompt: PromptRequest) -> some View {
        HStack(alignment: .center, spacing: 18) {
            AppIcon(path: prompt.executablePath, size: 72)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: prompt.appName)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)
                (Text("alert.wantsToConnect") + Text(verbatim: " ") + Text(verbatim: prompt.host ?? prompt.remoteIP).bold())
                    .font(.system(size: 14))
                    .lineLimit(2)
                if ![80, 443].contains(prompt.remotePort) {
                    Text("alert.onPort \(prompt.remotePort)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
    }

    private func options(_ prompt: PromptRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $lifetime) {
                Text("lifetime.once").tag(RuleLifetime.once)
                Text("lifetime.untilQuit").tag(RuleLifetime.untilQuit)
                Text("lifetime.forever").tag(RuleLifetime.forever)
            }
            .labelsHidden()
            .frame(width: 180)

            radio(selected: anyConnection) {
                anyConnection = true
            } label: {
                Text("alert.anyConnection")
            }
            radio(selected: !anyConnection) {
                anyConnection = false
            } label: {
                HStack(spacing: 4) {
                    Text("alert.only")
                    Menu {
                        ForEach(scopes(for: prompt), id: \.self) { s in
                            Button { scope = s; anyConnection = false } label: { scopeLabel(s) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            scopeLabel(scope)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func details(_ prompt: PromptRequest) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            detail("alert.detail.ip", prompt.remoteIP)
            detail("alert.detail.port", "\(prompt.remotePort) (TCP)")
            detail("alert.detail.path", prompt.executablePath)
            detail("alert.detail.pid", String(prompt.pid))
            detail("inspector.signedBy", CodeSigning.signer(of: prompt.executablePath) ?? RuleText.localized("inspector.unsigned"))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(_ prompt: PromptRequest) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("alert.autoDeny \(remaining)")
                if helper.prompts.count > 1 {
                    Text("alert.more \(helper.prompts.count - 1)")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .frame(width: 14)
            }
            .help(Text("alert.details"))
            Button {
                answer(prompt, .deny)
            } label: {
                Text("alert.deny").frame(width: 100)
            }
            .keyboardShortcut(.cancelAction)
            Button {
                answer(prompt, .allow)
            } label: {
                Text("alert.allow").frame(width: 100)
            }
            .buttonStyle(AllowButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 18)
    }

    private func radio<Label: View>(selected: Bool, action: @escaping () -> Void,
                                    @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            label()
        }
        .font(.system(size: 14))
    }

    private func detail(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(verbatim: value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    private func scopes(for prompt: PromptRequest) -> [Scope] {
        guard let host = prompt.host else { return [.ip(prompt.remoteIP)] }
        let domain = DomainName.registrable(host)
        var result: [Scope] = [.domain(domain)]
        if host != domain { result.append(.host(host)) }
        result.append(.ip(prompt.remoteIP))
        return result
    }

    @ViewBuilder
    private func scopeLabel(_ scope: Scope) -> some View {
        switch scope {
        case .domain(let d): Text("alert.scope.domain \(d)")
        case .host(let h): Text("alert.scope.host \(h)")
        case .ip(let ip): Text("alert.scope.ip \(ip)")
        }
    }

    private func reset(for prompt: PromptRequest) {
        anyConnection = false
        lifetime = .forever
        expanded = false
        scope = scopes(for: prompt).first ?? .ip(prompt.remoteIP)
        remaining = max(0, Int(prompt.deadline.timeIntervalSinceNow))
    }

    private func answer(_ prompt: PromptRequest, _ action: RuleAction) {
        helper.answer(prompt, action: action, lifetime: lifetime,
                      hostPattern: anyConnection ? nil : scope.pattern)
    }
}

/// Little Snitch's green Allow button, green even when the panel is not key.
private struct AllowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Palette.allow.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.12)))
    }
}
