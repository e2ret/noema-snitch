import Foundation

public enum RuleAction: String, Codable, CaseIterable, Hashable {
    case allow
    case deny
}

public enum RuleLifetime: String, Codable, CaseIterable, Hashable {
    /// Applies to the current connection only, never stored.
    case once
    /// Until the process that triggered it exits.
    case untilQuit
    /// Persisted.
    case forever
}

public struct Rule: Identifiable, Codable, Hashable {
    public var id = UUID()
    /// Exact executable path, or "*" for any process.
    public var executablePath: String
    public var appName: String
    public var action: RuleAction
    /// Host name or IP; "*.example.com" matches subdomains; nil = any host.
    public var host: String?
    /// nil = any port.
    public var port: Int?
    public var lifetime: RuleLifetime
    /// Process the rule is bound to when lifetime == .untilQuit.
    public var pid: Int32?
    public var enabled = true
    public var created = Date()

    public init(executablePath: String, appName: String, action: RuleAction,
                host: String? = nil, port: Int? = nil,
                lifetime: RuleLifetime = .forever, pid: Int32? = nil) {
        self.executablePath = executablePath
        self.appName = appName
        self.action = action
        self.host = host
        self.port = port
        self.lifetime = lifetime
        self.pid = pid
    }

    public func matches(executablePath path: String, host: String?, ip: String, port: Int) -> Bool {
        guard enabled else { return false }
        if executablePath != "*" && executablePath != path { return false }
        if let rulePort = self.port, rulePort != port { return false }
        guard let ruleHost = self.host?.lowercased() else { return true }
        let candidates = [host?.lowercased(), ip.lowercased()].compactMap { $0 }
        if ruleHost.hasPrefix("*.") {
            let base = String(ruleHost.dropFirst(2))
            return candidates.contains { $0 == base || $0.hasSuffix("." + base) }
        }
        return candidates.contains(ruleHost)
    }

    /// Higher wins: app-specific > any-app, host > any host, port > any port.
    public var specificity: Int {
        (executablePath == "*" ? 0 : 4) + (host == nil ? 0 : 2) + (port == nil ? 0 : 1)
    }

    /// Same target, so a new rule replaces the old one instead of piling up.
    public func sameTarget(as other: Rule) -> Bool {
        executablePath == other.executablePath
            && host?.lowercased() == other.host?.lowercased()
            && port == other.port
    }
}

public enum RuleMatcher {
    /// Most specific matching rule; on a tie deny wins.
    public static func match(_ rules: [Rule], executablePath: String,
                             host: String?, ip: String, port: Int) -> Rule? {
        rules
            .filter { $0.matches(executablePath: executablePath, host: host, ip: ip, port: port) }
            .max { a, b in
                (a.specificity, a.action == .deny ? 1 : 0) < (b.specificity, b.action == .deny ? 1 : 0)
            }
    }
}

public enum DomainName {
    /// Second-level suffixes where the registrable domain has three labels.
    private static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "com.au", "net.au", "org.au",
        "co.jp", "ne.jp", "or.jp", "co.kr", "co.nz", "co.in", "co.il", "co.za",
        "com.br", "com.cn", "com.tr", "com.mx", "com.ua", "com.ru", "msk.ru", "spb.ru",
        "com.sg", "com.hk", "com.tw", "com.ar", "com.pl",
    ]

    /// "imap.mail.com" → "mail.com"; IP addresses are returned unchanged.
    public static func registrable(_ host: String) -> String {
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiPartSuffixes.contains(lastTwo) { return labels.suffix(3).joined(separator: ".") }
        return lastTwo
    }
}
