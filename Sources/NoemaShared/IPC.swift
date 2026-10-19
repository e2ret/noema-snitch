import Foundation

/// Newline-delimited JSON over a Unix socket between the app (user) and the helper (root).
public enum IPC {
    public static let socketPath = "/var/run/com.noema.snitch.sock"
    public static let version = "1"

    public static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

public enum FilterMode: String, Codable, CaseIterable, Hashable {
    /// Ask about every connection without a rule.
    case alert
    /// Allow connections without a rule, without asking.
    case silentAllow
    /// Deny connections without a rule, without asking.
    case silentDeny
}

public struct HelperSettings: Codable, Hashable {
    /// When off, pf redirection is removed and traffic flows untouched.
    public var filteringEnabled = true
    public var mode: FilterMode = .alert
    /// Block UDP 443 so browsers fall back from QUIC to filterable TCP.
    public var blockQUIC = true
    /// Seconds the prompt waits before denying; 0 = wait until the user answers.
    public var promptTimeout = 0
    /// What to do when no app is connected to ask the user.
    public var actionWithoutUI: RuleAction = .allow
    /// Don't filter (or ask about) connections to the local network.
    public var allowLocalNetwork = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case filteringEnabled, mode, blockQUIC, promptTimeout, actionWithoutUI, allowLocalNetwork, schema
    }
    private static let schema = 2

    /// Missing keys keep their defaults, so adding a setting never resets the others.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HelperSettings()
        filteringEnabled = try c.decodeIfPresent(Bool.self, forKey: .filteringEnabled) ?? d.filteringEnabled
        mode = try c.decodeIfPresent(FilterMode.self, forKey: .mode) ?? d.mode
        blockQUIC = try c.decodeIfPresent(Bool.self, forKey: .blockQUIC) ?? d.blockQUIC
        actionWithoutUI = try c.decodeIfPresent(RuleAction.self, forKey: .actionWithoutUI) ?? d.actionWithoutUI
        allowLocalNetwork = try c.decodeIfPresent(Bool.self, forKey: .allowLocalNetwork) ?? d.allowLocalNetwork
        let schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        // Schema 1 had a 60 s default; prompts now wait for an answer.
        promptTimeout = schema < 2 ? 0 : (try c.decodeIfPresent(Int.self, forKey: .promptTimeout) ?? d.promptTimeout)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(filteringEnabled, forKey: .filteringEnabled)
        try c.encode(mode, forKey: .mode)
        try c.encode(blockQUIC, forKey: .blockQUIC)
        try c.encode(promptTimeout, forKey: .promptTimeout)
        try c.encode(actionWithoutUI, forKey: .actionWithoutUI)
        try c.encode(allowLocalNetwork, forKey: .allowLocalNetwork)
        try c.encode(Self.schema, forKey: .schema)
    }
}

public struct PromptRequest: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var pid: Int32
    public var executablePath: String
    public var appName: String
    public var remoteIP: String
    public var remotePort: Int
    /// From TLS SNI or HTTP Host header, when the client sent one.
    public var host: String?
    /// nil = the prompt waits until the user answers.
    public var deadline: Date?

    public init(pid: Int32, executablePath: String, appName: String, remoteIP: String,
                remotePort: Int, host: String?, deadline: Date?) {
        self.pid = pid
        self.executablePath = executablePath
        self.appName = appName
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        self.host = host
        self.deadline = deadline
    }
}

public struct Verdict: Codable, Hashable {
    public var requestID: UUID
    public var action: RuleAction
    public var lifetime: RuleLifetime
    /// Host, IP or "*.domain" the rule covers; nil = any connection of the app.
    public var hostPattern: String?

    public init(requestID: UUID, action: RuleAction, lifetime: RuleLifetime, hostPattern: String?) {
        self.requestID = requestID
        self.action = action
        self.lifetime = lifetime
        self.hostPattern = hostPattern
    }
}

public enum DecisionReason: String, Codable {
    case rule, user, timeout, noUI, filteringOff, silent
}

public struct TrafficEvent: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var date = Date()
    public var pid: Int32
    public var executablePath: String
    public var appName: String
    public var remoteIP: String
    public var remotePort: Int
    public var host: String?
    public var action: RuleAction
    public var reason: DecisionReason

    public init(pid: Int32, executablePath: String, appName: String, remoteIP: String,
                remotePort: Int, host: String?, action: RuleAction, reason: DecisionReason) {
        self.pid = pid
        self.executablePath = executablePath
        self.appName = appName
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        self.host = host
        self.action = action
        self.reason = reason
    }
}

/// Bytes moved since the previous report for one app + host, plus open connections.
public struct TrafficEntry: Codable, Hashable {
    public var executablePath: String
    public var appName: String
    public var pid: Int32
    public var host: String?
    public var ip: String
    public var port: Int
    public var sent: Int64
    public var received: Int64
    public var active: Int

    public init(executablePath: String, appName: String, pid: Int32, host: String?, ip: String,
                port: Int, sent: Int64, received: Int64, active: Int) {
        self.executablePath = executablePath
        self.appName = appName
        self.pid = pid
        self.host = host
        self.ip = ip
        self.port = port
        self.sent = sent
        self.received = received
        self.active = active
    }
}

/// Helper → app.
public enum HelperMessage: Codable {
    case hello(version: String, settings: HelperSettings)
    case rules([Rule])
    case prompt(PromptRequest)
    case promptResolved(UUID)
    case event(TrafficEvent)
    case traffic(date: Date, entries: [TrafficEntry])
}

/// App → helper.
public enum ClientMessage: Codable {
    case hello
    case verdict(Verdict)
    case upsertRule(Rule)
    case deleteRules([UUID])
    case setSettings(HelperSettings)
}
