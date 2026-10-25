import Foundation
import Network

/// One request a device sent through the proxy.
struct DeviceFlow: Identifiable, Hashable {
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

    var url: String {
        isHTTPS ? "https://\(host)\(port == 443 ? "" : ":\(port)")"
                : "http://\(host)\(port == 80 ? "" : ":\(port)")\(path ?? "/")"
    }

    var duration: TimeInterval? { ended.map { $0.timeIntervalSince(started) } }

    /// The iOS app, from the User-Agent iOS sends with each request:
    /// "Telegram/11.2 CFNetwork/1568 Darwin/24.0.0" → "Telegram".
    var app: String? {
        guard let ua = userAgent, let first = ua.split(separator: " ").first else { return nil }
        if first.hasPrefix("Mozilla") { return nil }  // a browser or web view
        let name = first.split(separator: "/").first.map(String.init) ?? String(first)
        return name.removingPercentEncoding ?? name
    }
}

/// HTTP proxy (plain HTTP + CONNECT tunnels) other devices on the network point at,
/// like Charles. It only relays and records — nothing is installed on the device,
/// so HTTPS stays encrypted: host, app, timing and size are visible, content is not.
final class DeviceProxyServer {
    private let queue = DispatchQueue(label: "noema.deviceproxy")
    private var listener: NWListener?
    private var flows: [UUID: DeviceFlow] = [:]
    private var changed = Set<UUID>()
    private var sessions: [UUID: ProxySession] = [:]

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

    /// Flows that changed since the last call.
    func drainChanges() -> [DeviceFlow] {
        queue.sync {
            let result = changed.compactMap { flows[$0] }
            changed.removeAll()
            // Finished flows are kept by the model; forget them here.
            for flow in result where flow.ended != nil { flows[flow.id] = nil }
            return result
        }
    }

    // MARK: - Called by sessions on `queue`

    fileprivate func update(_ flow: DeviceFlow) {
        flows[flow.id] = flow
        changed.insert(flow.id)
    }

    fileprivate func finished(_ session: ProxySession) {
        sessions[session.id] = nil
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
        let leftover = head[headEnd...]
        var lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return close(error: nil) }
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count == 3 else { return reply(400, "Bad Request") }
        let (method, target, version) = (requestLine[0], requestLine[1], requestLine[2])
        let userAgent = lines.first { $0.lowercased().hasPrefix("user-agent:") }
            .map { $0.dropFirst(11).trimmingCharacters(in: .whitespaces) }

        if method.uppercased() == "CONNECT" {
            let (host, port) = Self.splitHostPort(target, defaultPort: 443)
            flow = DeviceFlow(id: id, device: deviceAddress, started: Date(), method: "CONNECT", isHTTPS: true,
                              host: host, port: port, path: nil, userAgent: userAgent)
            report()
            connectUpstream(host: host, port: port) { [weak self] in
                guard let self else { return }
                self.client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                                 completion: .contentProcessed { _ in })
                if !leftover.isEmpty { self.forward(Data(leftover), up: true) }
                self.pipe(from: self.client, to: self.upstream!, up: true)
                self.pipe(from: self.upstream!, to: self.client, up: false)
            }
            return
        }

        // Plain HTTP: the target is an absolute URL.
        guard let url = URL(string: target), let host = url.host else { return reply(400, "Bad Request") }
        let port = url.port ?? 80
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query { path += "?" + query }
        flow = DeviceFlow(id: id, device: deviceAddress, started: Date(), method: method, isHTTPS: false,
                          host: host, port: port, path: path, userAgent: userAgent)
        report()

        // One request per connection keeps the log exact; ask both sides to close after it.
        var outgoing = "\(method) \(path) \(version)\r\n"
        for line in lines {
            let name = line.split(separator: ":").first.map { $0.lowercased() } ?? ""
            if ["proxy-connection", "proxy-authorization", "connection", "keep-alive"].contains(name) { continue }
            outgoing += line + "\r\n"
        }
        outgoing += "Connection: close\r\n\r\n"
        var request = Data(outgoing.utf8)
        request.append(contentsOf: leftover)

        connectUpstream(host: host, port: port) { [weak self] in
            guard let self else { return }
            self.forward(request, up: true)
            self.pipe(from: self.client, to: self.upstream!, up: true)
            self.pipe(from: self.upstream!, to: self.client, up: false, parseStatus: true)
        }
    }

    private func connectUpstream(host: String, port: Int, ready: @escaping () -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return reply(400, "Bad Request") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        upstream = connection
        var started = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready where !started:
                started = true
                ready()
            case .failed(let error), .waiting(let error):
                if !started { self.reply(502, "Bad Gateway", error: error.localizedDescription) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func forward(_ data: Data, up: Bool) {
        guard let target = up ? upstream : client else { return }
        target.send(content: data, completion: .contentProcessed { _ in })
        count(data.count, up: up)
    }

    private func pipe(from source: NWConnection, to destination: NWConnection, up: Bool, parseStatus: Bool = false) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                if parseStatus, self.flow?.status == nil { self.parseStatus(data) }
                destination.send(content: data, completion: .contentProcessed { _ in })
                self.count(data.count, up: up)
            }
            if done || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                 completion: .contentProcessed { _ in })
                self.openDirections -= 1
                if self.openDirections <= 0 || error != nil { self.close(error: nil) }
            } else {
                self.pipe(from: source, to: destination, up: up, parseStatus: parseStatus)
            }
        }
    }

    private func parseStatus(_ data: Data) {
        let line = String(decoding: data.prefix(64), as: UTF8.self)
        let parts = line.split(separator: " ")
        if parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) {
            flow?.status = code
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
        let body = "HTTP/1.1 \(code) \(text)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        client.send(content: Data(body.utf8), completion: .contentProcessed { [weak self] _ in
            self?.close(error: error ?? text)
        })
        if flow != nil { flow!.status = code }
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
