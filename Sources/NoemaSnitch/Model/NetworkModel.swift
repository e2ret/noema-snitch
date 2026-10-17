import Foundation
import NoemaShared

func byName(_ a: String, _ b: String, _ idA: String, _ idB: String) -> Bool {
    switch a.localizedStandardCompare(b) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: idA < idB
    }
}

struct TrafficPoint {
    var sent: Int64 = 0
    var received: Int64 = 0

    static func += (lhs: inout TrafficPoint, rhs: TrafficPoint) {
        lhs.sent += rhs.sent
        lhs.received += rhs.received
    }
}

/// Per-second byte counters in a ring buffer.
struct TrafficSeries {
    let capacity: Int
    private var buckets: [TrafficPoint]
    private var headSecond: Int

    init(capacity: Int) {
        self.capacity = capacity
        buckets = Array(repeating: TrafficPoint(), count: capacity)
        headSecond = Int(Date().timeIntervalSince1970)
    }

    mutating func add(second: Int, sent: Int64, received: Int64) {
        advance(to: second)
        guard second > headSecond - capacity else { return }
        buckets[index(second)] += TrafficPoint(sent: sent, received: received)
    }

    mutating func advance(to second: Int) {
        guard second > headSecond else { return }
        let steps = min(second - headSecond, capacity)
        for k in 1...steps { buckets[index(headSecond + k)] = TrafficPoint() }
        headSecond = second
    }

    /// `count` buckets covering the last `seconds` before `now`, oldest first.
    func points(seconds: Int, count: Int, now: Int) -> [TrafficPoint] {
        let span = min(seconds, capacity)
        let perBucket = max(1, span / count)
        let first = now - perBucket * count + 1
        return (0..<count).map { b in
            var p = TrafficPoint()
            for s in (first + b * perBucket)..<(first + (b + 1) * perBucket)
            where s <= headSecond && s > headSecond - capacity {
                p += buckets[index(s)]
            }
            return p
        }
    }

    private func index(_ second: Int) -> Int {
        ((second % capacity) + capacity) % capacity
    }
}

class TrafficNode: Identifiable {
    let id: String
    var name: String
    var totalSent: Int64 = 0
    var totalReceived: Int64 = 0
    var active = 0
    var denied = 0
    var lastSeen = Date.distantPast
    var series = TrafficSeries(capacity: 60)

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    func record(second: Int, sent: Int64, received: Int64) {
        totalSent += sent
        totalReceived += received
        series.add(second: second, sent: sent, received: received)
    }
}

final class HostNode: TrafficNode {
    /// Host name from SNI / Host header / reverse DNS; nil when only the IP is known.
    var hostname: String?
    var ips = Set<String>()
    var ports = Set<Int>()
}

final class DomainNode: TrafficNode {
    var hosts: [String: HostNode] = [:]

    var sortedHosts: [HostNode] {
        hosts.values.sorted { byName($0.name, $1.name, $0.id, $1.id) }
    }
}

final class AppNode: TrafficNode {
    let executablePath: String
    var pid: Int32 = 0
    var domains: [String: DomainNode] = [:]

    init(executablePath: String, name: String) {
        self.executablePath = executablePath
        super.init(id: executablePath, name: name)
    }

    var sortedDomains: [DomainNode] {
        domains.values.sorted { byName($0.name, $1.name, $0.id, $1.id) }
    }
}

/// Everything the Network Monitor shows: app → domain → host, with traffic.
@MainActor
final class NetworkModel: ObservableObject {
    @Published private(set) var revision = 0
    private(set) var apps: [String: AppNode] = [:]
    private(set) var global = TrafficSeries(capacity: 3600)
    private(set) var totalSent: Int64 = 0
    private(set) var totalReceived: Int64 = 0

    /// Stable alphabetical order so the list doesn't jump while traffic flows.
    var sortedApps: [AppNode] {
        apps.values.sorted { byName($0.name, $1.name, $0.id, $1.id) }
    }

    /// Most recently active first (status menu).
    var recentApps: [AppNode] {
        apps.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    func ingest(date: Date, entries: [TrafficEntry]) {
        let second = Int(date.timeIntervalSince1970)
        for e in entries {
            let (app, domain, host) = nodes(path: e.executablePath, appName: e.appName, host: e.host, ip: e.ip)
            app.pid = e.pid
            host.ports.insert(e.port)
            for node in [app, domain, host] as [TrafficNode] {
                node.record(second: second, sent: e.sent, received: e.received)
                node.lastSeen = date
            }
            host.active = e.active
            domain.active = domain.hosts.values.reduce(0) { $0 + $1.active }
            app.active = app.domains.values.reduce(0) { $0 + $1.active }
            global.add(second: second, sent: e.sent, received: e.received)
            totalSent += e.sent
            totalReceived += e.received
        }
        global.advance(to: second)
        revision += 1
    }

    func ingest(event: TrafficEvent) {
        guard event.action == .deny else { return }
        let (app, domain, host) = nodes(path: event.executablePath, appName: event.appName,
                                        host: event.host, ip: event.remoteIP)
        host.ports.insert(event.remotePort)
        for node in [app, domain, host] as [TrafficNode] {
            node.denied += 1
            node.lastSeen = event.date
        }
        revision += 1
    }

    /// Without the helper: list what libproc sees (no byte counts).
    func ingest(connections: [Connection], hostnames: [String: String]) {
        let now = Date()
        var seen = Set<String>()
        for c in connections where !c.executablePath.isEmpty {
            let name = hostnames[c.remoteAddress].flatMap { $0 == c.remoteAddress ? nil : $0 }
            let (app, domain, host) = nodes(path: c.executablePath, appName: c.displayName, host: name, ip: c.remoteAddress)
            app.pid = c.pid
            host.ports.insert(c.remotePort)
            for node in [app, domain, host] as [TrafficNode] where seen.insert(node.id).inserted {
                node.active = 0
                node.lastSeen = now
            }
            host.active += 1
            domain.active += 1
            app.active += 1
        }
        for app in apps.values where !seen.contains(app.id) {
            app.active = 0
            app.domains.values.forEach { d in
                d.active = 0
                d.hosts.values.forEach { $0.active = 0 }
            }
        }
        revision += 1
    }

    func tick() {
        global.advance(to: Int(Date().timeIntervalSince1970))
        revision += 1
    }

    func clear() {
        apps.removeAll()
        revision += 1
    }

    func app(_ id: String) -> AppNode? { apps[id] }

    private func nodes(path: String, appName: String, host: String?, ip: String) -> (AppNode, DomainNode, HostNode) {
        let app = apps[path] ?? {
            let node = AppNode(executablePath: path, name: appName)
            apps[path] = node
            return node
        }()
        let hostKey = host ?? ip
        let domainKey = host.map(DomainName.registrable) ?? ip
        let domain = app.domains[domainKey] ?? {
            let node = DomainNode(id: "\(path)|\(domainKey)", name: domainKey)
            app.domains[domainKey] = node
            return node
        }()
        let hostNode = domain.hosts[hostKey] ?? {
            let node = HostNode(id: "\(path)|\(domainKey)|\(hostKey)", name: hostKey)
            node.hostname = host
            domain.hosts[hostKey] = node
            return node
        }()
        hostNode.ips.insert(ip)
        return (app, domain, hostNode)
    }
}
