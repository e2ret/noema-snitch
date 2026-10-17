import Darwin
import Foundation
import NoemaShared

/// Owns rules and settings, matches connections and asks the user when no rule applies.
final class DecisionEngine {
    private struct Pending {
        var prompt: PromptRequest
        var request: ConnectionRequest
        var completions: [(RuleAction, DecisionReason) -> Void]
    }

    weak var ipc: IPCServer?
    var onSettingsChanged: ((HelperSettings) -> Void)?

    private let queue = DispatchQueue(label: "noema.engine")
    private var rules: [Rule] = []
    private(set) var settings = HelperSettings()
    private var pending: [String: Pending] = [:]

    private static let directory = URL(fileURLWithPath: "/Library/Application Support/NoemaSnitch", isDirectory: true)
    private static let rulesURL = directory.appendingPathComponent("rules.json")
    private static let settingsURL = directory.appendingPathComponent("settings.json")

    init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.rulesURL), let stored = IPC.decode([Rule].self, from: data) {
            rules = stored
        }
        if let data = try? Data(contentsOf: Self.settingsURL), let stored = IPC.decode(HelperSettings.self, from: data) {
            settings = stored
        }
    }

    // MARK: - Decisions

    func decide(_ request: ConnectionRequest, completion: @escaping (RuleAction) -> Void) {
        queue.async { [self] in
            func finish(_ action: RuleAction, _ reason: DecisionReason) {
                completion(action)
                emit(request, action, reason)
            }

            guard settings.filteringEnabled else { return finish(.allow, .filteringOff) }
            dropDeadProcessRules()

            if let rule = RuleMatcher.match(rules, executablePath: request.executablePath,
                                            host: request.host, ip: request.destination.ip,
                                            port: Int(request.destination.port)) {
                return finish(rule.action, .rule)
            }

            switch settings.mode {
            case .silentAllow: return finish(.allow, .silent)
            case .silentDeny: return finish(.deny, .silent)
            case .alert: break
            }

            guard ipc?.hasClients == true else {
                return finish(settings.actionWithoutUI, .noUI)
            }

            // One prompt per app + host; further connections wait on it.
            let key = "\(request.executablePath)|\(request.host ?? request.destination.ip)"
            let wrapped: (RuleAction, DecisionReason) -> Void = { [weak self] action, reason in
                completion(action)
                self?.emit(request, action, reason)
            }
            if pending[key] != nil {
                pending[key]?.completions.append(wrapped)
                return
            }
            let prompt = PromptRequest(
                pid: request.pid,
                executablePath: request.executablePath,
                appName: request.appName,
                remoteIP: request.destination.ip,
                remotePort: Int(request.destination.port),
                host: request.host,
                deadline: settings.promptTimeout > 0
                    ? Date().addingTimeInterval(TimeInterval(settings.promptTimeout)) : nil
            )
            pending[key] = Pending(prompt: prompt, request: request, completions: [wrapped])
            ipc?.broadcast(.prompt(prompt))

            let promptID = prompt.id
            guard settings.promptTimeout > 0 else { return }
            queue.asyncAfter(deadline: .now() + .seconds(settings.promptTimeout)) { [weak self] in
                guard let self, let (key, entry) = self.pending.first(where: { $0.value.prompt.id == promptID }) else { return }
                self.pending[key] = nil
                self.ipc?.broadcast(.promptResolved(promptID))
                entry.completions.forEach { $0(.deny, .timeout) }
            }
        }
    }

    /// The last app window disconnected: nobody can answer the waiting prompts.
    func clientsGone() {
        queue.async { [self] in
            let waiting = pending
            pending.removeAll()
            for entry in waiting.values {
                entry.completions.forEach { $0(settings.actionWithoutUI, .noUI) }
            }
        }
    }

    func apply(_ verdict: Verdict) {
        queue.async { [self] in
            guard let (key, entry) = pending.first(where: { $0.value.prompt.id == verdict.requestID }) else { return }
            pending[key] = nil
            ipc?.broadcast(.promptResolved(verdict.requestID))
            entry.completions.forEach { $0(verdict.action, .user) }

            // Never store a rule for a connection whose process we could not identify.
            guard verdict.lifetime != .once, !entry.prompt.executablePath.isEmpty else { return }
            let prompt = entry.prompt
            let rule = Rule(executablePath: prompt.executablePath,
                            appName: prompt.appName,
                            action: verdict.action,
                            host: verdict.hostPattern,
                            lifetime: verdict.lifetime,
                            pid: verdict.lifetime == .untilQuit ? prompt.pid : nil)
            insert(rule)
            resolvePendingByRules()
        }
    }

    // MARK: - Rules & settings

    func snapshot(_ body: @escaping (HelperSettings, [Rule], [PromptRequest]) -> Void) {
        queue.async { [self] in body(settings, rules, pending.values.map(\.prompt)) }
    }

    func upsert(_ rule: Rule) {
        queue.async { [self] in
            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[index] = rule
                rulesChanged()
            } else {
                insert(rule)
            }
            resolvePendingByRules()
        }
    }

    func delete(_ ids: [UUID]) {
        queue.async { [self] in
            rules.removeAll { ids.contains($0.id) }
            rulesChanged()
        }
    }

    func update(_ newSettings: HelperSettings) {
        queue.async { [self] in
            settings = newSettings
            if let data = IPC.encode(settings) { try? data.write(to: Self.settingsURL, options: .atomic) }
            onSettingsChanged?(settings)
            ipc?.broadcast(.hello(version: IPC.version, settings: settings))
        }
    }

    private func insert(_ rule: Rule) {
        rules.removeAll { $0.sameTarget(as: rule) }
        rules.append(rule)
        rulesChanged()
    }

    private func rulesChanged() {
        let persistent = rules.filter { $0.lifetime == .forever }
        if let data = IPC.encode(persistent) { try? data.write(to: Self.rulesURL, options: .atomic) }
        ipc?.broadcast(.rules(rules))
    }

    /// A new rule may answer other waiting prompts (e.g. "any host" for the app).
    private func resolvePendingByRules() {
        for (key, entry) in pending {
            let p = entry.prompt
            guard let rule = RuleMatcher.match(rules, executablePath: p.executablePath, host: p.host,
                                               ip: p.remoteIP, port: p.remotePort) else { continue }
            pending[key] = nil
            ipc?.broadcast(.promptResolved(p.id))
            entry.completions.forEach { $0(rule.action, .rule) }
        }
    }

    private func dropDeadProcessRules() {
        let before = rules.count
        rules.removeAll { rule in
            guard rule.lifetime == .untilQuit, let pid = rule.pid else { return false }
            return kill(pid, 0) != 0 && errno == ESRCH
        }
        if rules.count != before { rulesChanged() }
    }

    private func emit(_ request: ConnectionRequest, _ action: RuleAction, _ reason: DecisionReason) {
        ipc?.broadcast(.event(TrafficEvent(
            pid: request.pid,
            executablePath: request.executablePath,
            appName: request.appName,
            remoteIP: request.destination.ip,
            remotePort: Int(request.destination.port),
            host: request.host,
            action: action,
            reason: reason
        )))
    }
}
