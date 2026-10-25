import Darwin
import Foundation
import Network

/// Phase durations of one request, in seconds.
struct FlowTiming: Codable, Hashable {
    var dns: TimeInterval?
    var connect: TimeInterval?
    var tls: TimeInterval?
    var firstByte: TimeInterval?
}

/// One request a device sent through the proxy.
struct DeviceFlow: Identifiable, Hashable, Codable {
    let id: UUID
    let device: String
    let started: Date
    var ended: Date?
    /// "CONNECT" for HTTPS tunnels, otherwise the HTTP method.
    let method: String
    let isHTTPS: Bool
    let host: String
    let port: Int
    /// Path and query for plain HTTP; nil for HTTPS (encrypted).
    let path: String?
    let userAgent: String?
    var status: Int?
    var sent: Int64 = 0
    var received: Int64 = 0
    var error: String?
    /// Address actually connected to.
    var remoteIP: String?
    var timing = FlowTiming()
    var tls: TLSInfo?
    /// Refused by access control.
    var blocked = false
    /// Sent through the external (upstream) proxy.
    var viaUpstream = false

    /// Host as the app meant it: the TLS SNI wins over a bare IP in CONNECT.
    var displayHost: String { tls?.sni ?? host }

    var url: String {
        isHTTPS ? "https://\(displayHost)\(port == 443 ? "" : ":\(port)")"
                : "http://\(host)\(port == 80 ? "" : ":\(port)")\(path ?? "/")"
    }

    var duration: TimeInterval? { ended.map { $0.timeIntervalSince(started) } }

    /// "Home Assistant/2024.10 (…)" → "Home Assistant", "Instagram 352.0 (iPhone…)" → "Instagram".
    var app: String? {
        guard let ua = userAgent?.trimmingCharacters(in: .whitespaces), !ua.isEmpty,
              !ua.hasPrefix("Mozilla") else { return nil }  // browsers and web views
        var name = String(ua.prefix { $0 != "/" && $0 != "(" })
        // Drop a trailing version ("Instagram 352.0") and spaces.
        var words = name.split(separator: " ")
        while words.count > 1, let last = words.last, last.first?.isNumber == true { words.removeLast() }
        name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return name.removingPercentEncoding ?? name
    }
}

enum ThrottleProfile: String, CaseIterable, Codable, Identifiable {
    case off, edge, threeG, lte, badWiFi
    var id: String { rawValue }

    /// (download bytes/s, upload bytes/s, one-way latency s)
    var limits: (down: Double, up: Double, latency: Double)? {
        switch self {
        case .off: nil
        case .edge: (240_000 / 8, 200_000 / 8, 0.40)
        case .threeG: (750_000 / 8, 250_000 / 8, 0.10)
        case .lte: (4_000_000 / 8, 1_000_000 / 8, 0.05)
        case .badWiFi: (1_000_000 / 8, 500_000 / 8, 0.20)
        }
    }
}

struct DeviceProxyConfig: Codable, Equatable {
    enum Access: String, Codable, CaseIterable {
        /// Any device on the local network (private addresses only).
        case localNetwork
        /// Only devices the user allowed.
        case selected
    }

    var access: Access = .localNetwork
    var allowedDevices: Set<String> = []
    var recording = true
    var throttle: ThrottleProfile = .off
    var upstreamEnabled = false
    var upstreamHost = "127.0.0.1"
    var upstreamPort = 7890
}

/// HTTP proxy (plain HTTP + CONNECT tunnels) other devices on the network point at,
/// like Charles. It only relays and records — nothing is installed on the device,
/// so HTTPS stays encrypted: host, app, TLS handshake, timing and size are visible.
final class DeviceProxyServer {
    private let queue = DispatchQueue(label: "noema.deviceproxy")
    private var listener: NWListener?
    private var flows: [UUID: DeviceFlow] = [:]
    private var changed = Set<UUID>()
    private var sessions: [UUID: ProxySession] = [:]
    fileprivate private(set) var config = DeviceProxyConfig()

    /// Called on the proxy queue when the listener fails.
    var onFailure: ((String) -> Void)?

    func start(port: UInt16) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let session = ProxySession(client: connection, server: self, queue: self.queue)
            self.sessions[session.id] = session
            session.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onFailure?(error.localizedDescription) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            sessions.values.forEach { $0.close(error: nil) }
            sessions.removeAll()
        }
    }

    func apply(_ config: DeviceProxyConfig) {
        queue.async { self.config = config }
    }

    /// Flows that changed since the last call.
    func drainChanges() -> [DeviceFlow] {
        queue.sync {
            let result = changed.compactMap { flows[$0] }
            changed.removeAll()
            for flow in result where flow.ended != nil { flows[flow.id] = nil }
            return result
        }
    }

    // MARK: - Called by sessions on `queue`

    fileprivate func update(_ flow: DeviceFlow) {
        guard config.recording else { return }
        flows[flow.id] = flow
        changed.insert(flow.id)
    }

    fileprivate func finished(_ session: ProxySession) {
        sessions[session.id] = nil
    }

    /// Private, loopback, link-local and unique-local addresses: the local network.
    static func isLocal(_ ip: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let a = UInt32(bigEndian: v4.s_addr)
            let o1 = a >> 24, o2 = (a >> 16) & 0xff
            return o1 == 10 || o1 == 127 || (o1 == 172 && (16...31).contains(o2))
                || (o1 == 192 && o2 == 168) || (o1 == 169 && o2 == 254)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, ip, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }  // ::1
            return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)  // fc00::/7, fe80::/10
        }
        return false
    }
}

private final class ProxySession {
    let id = UUID()
    private let client: NWConnection
    private var upstream: NWConnection?
    private unowned let server: DeviceProxyServer
    private let queue: DispatchQueue
    private var head = Data()
    private var flow: DeviceFlow?
    private var openDirections = 2
    private var closed = false
    private var tls = TLSInspector()
    private var tlsStart: Date?
    private var requestSent: Date?
    private var deliverUp = DispatchTime.now()
    private var deliverDown = DispatchTime.now()

    private static let headEnd = Data("\r\n\r\n".utf8)
    private static let maxHead = 64 * 1024

    init(client: NWConnection, server: DeviceProxyServer, queue: DispatchQueue) {
        self.client = client
        self.server = server
        self.queue = queue
    }

    func start() {
        client.start(queue: queue)
        readHead()
    }

    private var deviceAddress: String {
        if case .hostPort(let host, _) = client.endpoint {
            var text = "\(host)"
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }  // drop IPv6 zone
            if text.hasPrefix("::ffff:") { text = String(text.dropFirst(7)) }
            return text
        }
        return "?"
    }

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.head.append(data) }
            if let range = self.head.range(of: Self.headEnd) {
                self.handleRequest(headEnd: range.upperBound)
            } else if done || error != nil || self.head.count > Self.maxHead {
                self.close(error: nil)
            } else {
                self.readHead()
            }
        }
    }

    private func handleRequest(headEnd: Data.Index) {
        let text = String(decoding: head[head.startIndex..<headEnd], as: UTF8.self)
        let leftover = Data(head[headEnd...])
        var lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return close(error: nil) }
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count == 3 else { return reply(400, "Bad Request") }
        let (method, target, version) = (requestLine[0], requestLine[1], requestLine[2])
        let userAgent = lines.first { $0.lowercased().hasPrefix("user-agent:") }
            .map { $0.dropFirst(11).trimmingCharacters(in: .whitespaces) }
        let device = deviceAddress
        let isConnect = method.uppercased() == "CONNECT"

        let host: String, port: Int, path: String?
        if isConnect {
            (host, port) = Self.splitHostPort(target, defaultPort: 443)
            path = nil
        } else {
            guard let url = URL(string: target), let h = url.host else { return reply(400, "Bad Request") }
            host = h
            port = url.port ?? 80
            var p = url.path.isEmpty ? "/" : url.path
            if let query = url.query { p += "?" + query }
            path = p
        }
        flow = DeviceFlow(id: id, device: device, started: Date(), method: isConnect ? "CONNECT" : method,
                          isHTTPS: isConnect, host: host, port: port, path: path, userAgent: userAgent)

        // Access control: only the local network, and only allowed devices when restricted.
        let config = server.config
        if !DeviceProxyServer.isLocal(device)
            || (config.access == .selected && !config.allowedDevices.contains(device)) {
            flow?.blocked = true
            return reply(403, "Forbidden", error: "access denied")
        }
        report()

        if isConnect {
            connectUpstream(host: host, port: port) { [weak self] in
                guard let self, let upstream = self.upstream else { return }
                self.client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                                 completion: .contentProcessed { _ in })
                self.tlsStart = Date()
                if !leftover.isEmpty { self.relay(leftover, to: upstream, up: true) {} }
                self.pipe(from: self.client, to: upstream, up: true)
                self.pipe(from: upstream, to: self.client, up: false)
            }
            return
        }

        // Plain HTTP. One request per connection keeps the log exact.
        var outgoing = "\(method) \(path ?? "/") \(version)\r\n"
        for line in lines {
            let name = line.split(separator: ":").first.map { $0.lowercased() } ?? ""
            if ["proxy-connection", "proxy-authorization", "connection", "keep-alive"].contains(name) { continue }
            outgoing += line + "\r\n"
        }
        outgoing += "Connection: close\r\n\r\n"
        var request = Data(outgoing.utf8)
        request.append(leftover)

        connectUpstream(host: host, port: port) { [weak self] in
            guard let self, let upstream = self.upstream else { return }
            self.requestSent = Date()
            self.relay(request, to: upstream, up: true) {}
            self.pipe(from: self.client, to: upstream, up: true)
            self.pipe(from: upstream, to: self.client, up: false)
        }
    }

    // MARK: - Connecting: DNS → TCP (→ external proxy)

    private func connectUpstream(host: String, port: Int, ready: @escaping () -> Void) {
        let config = server.config
        if config.upstreamEnabled {
            flow?.viaUpstream = true
            return connectViaProxy(host: host, port: port, config: config, ready: ready)
        }
        // Resolve ourselves to time DNS separately; getaddrinfo blocks, so off the proxy queue.
        let dnsStart = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let address = Self.resolve(host)
            self?.queue.async {
                guard let self, !self.closed else { return }
                self.flow?.timing.dns = Date().timeIntervalSince(dnsStart)
                guard let address else {
                    return self.reply(502, "Bad Gateway", error: "DNS: \(host)")
                }
                self.flow?.remoteIP = address
                self.open(NWEndpoint.Host(address), port: port) { ready() }
            }
        }
    }

    private func connectViaProxy(host: String, port: Int, config: DeviceProxyConfig, ready: @escaping () -> Void) {
        open(NWEndpoint.Host(config.upstreamHost), port: config.upstreamPort) { [weak self] in
            guard let self, let upstream = self.upstream else { return }
            let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
            upstream.send(content: Data("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n".utf8),
                          completion: .contentProcessed { _ in })
            self.readProxyReply(Data(), ready: ready)
        }
    }

    private func readProxyReply(_ buffer: Data, ready: @escaping () -> Void) {
        upstream?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Self.headEnd) {
                let statusLine = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    .components(separatedBy: "\r\n").first ?? ""
                let code = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) }
                guard code == 200 else {
                    return self.reply(502, "Bad Gateway", error: "upstream proxy: \(statusLine)")
                }
                ready()
            } else if done || error != nil || buffer.count > 16384 {
                self.reply(502, "Bad Gateway", error: "upstream proxy closed the connection")
            } else {
                self.readProxyReply(buffer, ready: ready)
            }
        }
    }

    private func open(_ host: NWEndpoint.Host, port: Int, ready: @escaping () -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return reply(400, "Bad Request") }
        let connectStart = Date()
        let connection = NWConnection(host: host, port: nwPort, using: .tcp)
        upstream = connection
        var started = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready where !started:
                started = true
                self.flow?.timing.connect = Date().timeIntervalSince(connectStart)
                self.report()
                ready()
            case .failed(let error), .waiting(let error):
                if !started { self.reply(502, "Bad Gateway", error: error.localizedDescription) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private static func resolve(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        // Prefer IPv4: home routers often lack working IPv6 to the internet.
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var chosen = first
        while let ai = cursor {
            if ai.pointee.ai_family == AF_INET { chosen = ai; break }
            cursor = ai.pointee.ai_next
        }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(chosen.pointee.ai_addr, chosen.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Relaying

    private func pipe(from source: NWConnection, to destination: NWConnection, up: Bool) {
        let chunk = server.config.throttle == .off ? 256 * 1024 : 16 * 1024
        source.receive(minimumIncompleteLength: 1, maximumLength: chunk) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            let next = { [weak self] in
                guard let self, !self.closed else { return }
                if done || error != nil {
                    // When throttling, data may still be scheduled: finish only after the last piece.
                    let lastDelivery = up ? self.deliverUp : self.deliverDown
                    let finishAt = max(DispatchTime.now(), lastDelivery) + 0.01
                    self.queue.asyncAfter(deadline: finishAt) { [weak self] in
                        guard let self, !self.closed else { return }
                        destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                         completion: .contentProcessed { _ in })
                        self.openDirections -= 1
                        if self.openDirections <= 0 || error != nil { self.close(error: nil) }
                    }
                } else {
                    self.pipe(from: source, to: destination, up: up)
                }
            }
            if let data, !data.isEmpty {
                self.observe(data, up: up)
                self.relay(data, to: destination, up: up, then: next)
            } else {
                next()
            }
        }
    }

    /// Sends now, or later when throttling, and calls `then` when more can be read.
    private func relay(_ data: Data, to destination: NWConnection, up: Bool, then: @escaping () -> Void) {
        count(data.count, up: up)
        guard let limits = server.config.throttle.limits else {
            destination.send(content: data, completion: .contentProcessed { _ in })
            return then()
        }
        let rate = up ? limits.up : limits.down
        let now = DispatchTime.now()
        let earliest = now + limits.latency
        let previous = up ? deliverUp : deliverDown
        let deliverAt = max(earliest, previous) + Double(data.count) / rate
        if up { deliverUp = deliverAt } else { deliverDown = deliverAt }
        queue.asyncAfter(deadline: deliverAt) { [weak self] in
            guard let self, !self.closed else { return }
            destination.send(content: data, completion: .contentProcessed { _ in })
        }
        // Keep at most ~1 s of data queued, so a big download doesn't pile up in memory.
        let backlog = Double(deliverAt.uptimeNanoseconds - now.uptimeNanoseconds) / 1e9
        if backlog > 1 {
            queue.asyncAfter(deadline: now + (backlog - 0.5)) { then() }
        } else {
            then()
        }
    }

    /// Watches the first bytes: TLS hellos for tunnels, the status line for HTTP.
    private func observe(_ data: Data, up: Bool) {
        guard flow != nil else { return }
        if flow!.isHTTPS {
            let parsed = up ? tls.client(data) : tls.server(data)
            if parsed {
                flow!.tls = tls.info
                if !up, let start = tlsStart { flow!.timing.tls = Date().timeIntervalSince(start) }
            }
            if !up, flow!.timing.firstByte == nil, let start = tlsStart {
                flow!.timing.firstByte = Date().timeIntervalSince(start)
            }
        } else if !up, flow!.status == nil {
            if let sent = requestSent { flow!.timing.firstByte = Date().timeIntervalSince(sent) }
            let line = String(decoding: data.prefix(64), as: UTF8.self)
            let parts = line.split(separator: " ")
            if parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) { flow!.status = code }
        }
    }

    private func count(_ bytes: Int, up: Bool) {
        guard flow != nil else { return }
        if up { flow!.sent += Int64(bytes) } else { flow!.received += Int64(bytes) }
        report()
    }

    private func report() {
        if let flow { server.update(flow) }
    }

    private func reply(_ code: Int, _ text: String, error: String? = nil) {
        let body = code == 403
            ? "Noema Snitch: this device is not allowed to use the proxy.\n"
            : ""
        let response = "HTTP/1.1 \(code) \(text)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        if flow != nil { flow!.status = code }
        client.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.close(error: error ?? text)
        })
    }

    func close(error: String?) {
        guard !closed else { return }
        closed = true
        if flow != nil {
            flow!.ended = Date()
            if let error { flow!.error = error }
            report()
        }
        client.cancel()
        upstream?.cancel()
        server.finished(self)
    }

    private static func splitHostPort(_ target: String, defaultPort: Int) -> (String, Int) {
        if target.hasPrefix("["), let end = target.firstIndex(of: "]") {  // [IPv6]:port
            let host = String(target[target.index(after: target.startIndex)..<end])
            let rest = target[target.index(after: end)...]
            return (host, Int(rest.dropFirst()) ?? defaultPort)
        }
        if let colon = target.lastIndex(of: ":"), let port = Int(target[target.index(after: colon)...]) {
            return (String(target[..<colon]), port)
        }
        return (target, defaultPort)
    }
}
