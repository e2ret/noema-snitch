import Foundation
import NoemaShared

/// Connection from the app to the root helper: rules, settings, prompts and events.
@MainActor
final class HelperClient: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var rules: [Rule] = []
    @Published private(set) var settings = HelperSettings()
    @Published private(set) var prompts: [PromptRequest] = []
    @Published private(set) var events: [TrafficEvent] = []

    /// Forwarded to the network model.
    var onTraffic: ((Date, [TrafficEntry]) -> Void)?
    var onEvent: ((TrafficEvent) -> Void)?

    private var channel: LineChannel?
    private var connecting = false
    private var timer: Timer?
    private let ioQueue = DispatchQueue(label: "noema.client")
    private static let maxEvents = 2000

    init() {
        guard !Demo.isEnabled else { return }
        connect()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.connect() }
        }
    }

    // MARK: - Commands

    func answer(_ prompt: PromptRequest, action: RuleAction, lifetime: RuleLifetime, hostPattern: String?) {
        prompts.removeAll { $0.id == prompt.id }
        send(.verdict(Verdict(requestID: prompt.id, action: action, lifetime: lifetime, hostPattern: hostPattern)))
    }

    /// Creates or replaces the rule for this app and target.
    func setRule(_ action: RuleAction, executablePath: String, appName: String, hostPattern: String?) {
        if var existing = rules.first(where: {
            $0.executablePath == executablePath && $0.host == hostPattern && $0.port == nil
        }) {
            existing.action = action
            existing.lifetime = .forever
            existing.enabled = true
            upsert(existing)
        } else {
            upsert(Rule(executablePath: executablePath, appName: appName, action: action, host: hostPattern))
        }
    }

    func upsert(_ rule: Rule) {
        send(.upsertRule(rule))
    }

    func deleteRules(_ ids: Set<UUID>) {
        send(.deleteRules(Array(ids)))
    }

    func update(_ change: (inout HelperSettings) -> Void) {
        var copy = settings
        change(&copy)
        settings = copy
        send(.setSettings(copy))
    }

    func loadDemo(rules: [Rule], prompts: [PromptRequest]) {
        self.rules = rules
        self.prompts = prompts
    }

    func clearEvents() {
        events.removeAll()
    }

    func rule(for path: String, host: String?, ip: String, port: Int) -> Rule? {
        RuleMatcher.match(rules, executablePath: path, host: host, ip: ip, port: port)
    }

    // MARK: - Connection

    private func send(_ message: ClientMessage) {
        channel?.send(message)
    }

    private func connect() {
        guard channel == nil, !connecting else { return }
        connecting = true
        ioQueue.async {
            let fd = UnixSocket.connect(path: IPC.socketPath)
            DispatchQueue.main.async {
                self.connecting = false
                if let fd { self.attach(fd) }
            }
        }
    }

    private func attach(_ fd: Int32) {
        let channel = LineChannel(fd: fd, queue: ioQueue)
        channel.onLine = { [weak self] data in
            guard let message = IPC.decode(HelperMessage.self, from: data) else { return }
            DispatchQueue.main.async { self?.handle(message) }
        }
        channel.onClose = { [weak self] in
            DispatchQueue.main.async {
                self?.channel = nil
                self?.isConnected = false
                self?.prompts.removeAll()
            }
        }
        self.channel = channel
        channel.start()
        isConnected = true
        send(.hello)
    }

    private func handle(_ message: HelperMessage) {
        switch message {
        case .hello(_, let settings):
            self.settings = settings
        case .rules(let rules):
            self.rules = rules
        case .prompt(let prompt):
            if !prompts.contains(where: { $0.id == prompt.id }) { prompts.append(prompt) }
        case .promptResolved(let id):
            prompts.removeAll { $0.id == id }
        case .event(let event):
            events.insert(event, at: 0)
            if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
            onEvent?(event)
        case .traffic(let date, let entries):
            onTraffic?(date, entries)
        }
    }
}
