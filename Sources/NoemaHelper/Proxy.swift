import Darwin
import Foundation
import NoemaShared

struct ConnectionRequest {
    let pid: Int32
    let executablePath: String
    /// Code-signature identity, so rules survive app updates.
    let signingID: String?
    let appName: String
    let destination: SocketAddress
    let host: String?
}

/// Accepts connections pf redirected to us, asks the engine, then either
/// resets the client or relays it to the original destination.
final class Proxy {
    static let port: UInt16 = 47900

    private let pf: PFController
    private let engine: DecisionEngine
    private let ledger: TrafficLedger
    private let flows = FlowLookup()
    private let acceptQueue = DispatchQueue(label: "noema.accept")
    private let workQueue = DispatchQueue(label: "noema.connection", attributes: .concurrent)
    private var sources: [DispatchSourceRead] = []
    private var localAddresses = SocketAddress.interfaceAddresses()

    init(pf: PFController, engine: DecisionEngine, ledger: TrafficLedger) {
        self.pf = pf
        self.engine = engine
        self.ledger = ledger
    }

    func start() throws {
        try listen(on: .loopback(family: AF_INET, port: Self.port))
        do {
            try listen(on: .loopback(family: AF_INET6, port: Self.port))
        } catch {
            log("IPv6 listener unavailable: \(error)")
        }
    }

    private func listen(on address: SocketAddress) throws {
        let fd = socket(address.family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        if address.family == AF_INET6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        var (ss, len) = address.storage()
        let bound = withUnsafePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, Darwin.listen(fd, 1024) == 0 else {
            let err = errno
            close(fd)
            throw POSIXError(.init(rawValue: err) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                self?.workQueue.async { self?.handle(client) }
            }
        }
        source.resume()
        sources.append(source)
        log("proxy listening on \(address)")
    }

    private func handle(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        guard let peer = SocketAddress.peer(of: fd),
              let local = SocketAddress.local(of: fd),
              let destination = pf.originalDestination(peer: peer, local: local) else {
            log("no original destination for client; dropping")
            Self.reset(fd)
            return
        }

        // The client's socket can be briefly invisible right after connect; retry a few times.
        var owner = SocketScanner.owner(ofTCPPort: Int(peer.port), excluding: getpid())
        for _ in 0..<3 where owner == nil {
            usleep(20_000)
            owner = SocketScanner.owner(ofTCPPort: Int(peer.port), excluding: getpid())
        }
        // Daemons on Apple's user-space network stack have no BSD socket; ask NetworkStatistics.
        if owner == nil, let pid = flows.pid(forLocalPort: peer.port), pid != getpid() {
            owner = SocketScanner.ProcessInfo(pid: pid,
                                              executablePath: SocketScanner.executablePath(of: pid) ?? "",
                                              processName: SocketScanner.processName(of: pid) ?? "")
        }
        if owner == nil {
            log("could not identify process for \(peer) → \(destination)")
        }
        let path = owner?.executablePath ?? ""
        let request = ConnectionRequest(
            pid: owner?.pid ?? 0,
            executablePath: path,
            signingID: CodeIdentity.of(path),
            appName: AppIdentity.displayName(executablePath: path, processName: owner?.processName ?? "?"),
            destination: destination,
            host: Sniffer.host(fd: fd, timeoutMs: 300)
        )

        engine.decide(request) { [weak self] action in
            self?.workQueue.async {
                guard let self else { return }
                guard action == .allow else {
                    Self.reset(fd)
                    return
                }
                // Our own sockets to this Mac's addresses would loop back
                // through the lo0 redirect, so go via loopback instead.
                var target = destination
                if self.localAddresses.contains(target.bytes) {
                    target = .loopback(family: target.family, port: target.port)
                }
                guard let upstream = Self.connect(to: target, timeoutSeconds: 15) else {
                    Self.reset(fd)
                    return
                }
                let key = self.ledger.open(request)
                let ledger = self.ledger
                Relay(client: fd, upstream: upstream,
                      onBytes: { sent, received in ledger.add(key, sent: sent, received: received) },
                      onFinish: { ledger.close(key) }).start()
            }
        }
    }

    /// Close with RST so the client fails fast instead of waiting.
    static func reset(_ fd: Int32) {
        var lingerOff = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &lingerOff, socklen_t(MemoryLayout<linger>.size))
        close(fd)
    }

    static func connect(to address: SocketAddress, timeoutSeconds: Int32) -> Int32? {
        let fd = socket(address.family, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var (ss, len) = address.storage()
        let r = withUnsafePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if r != 0 {
            guard errno == EINPROGRESS else {
                close(fd)
                return nil
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var err: Int32 = 0
            var errLen = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&pfd, 1, timeoutSeconds * 1000) > 0,
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen) == 0, err == 0 else {
                close(fd)
                return nil
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }
}

/// Copies bytes both ways until each side has closed.
final class Relay {
    private let client: Int32
    private let upstream: Int32
    private let queue = DispatchQueue(label: "noema.relay")
    private var clientIO: DispatchIO?
    private var upstreamIO: DispatchIO?
    private var openDirections = 2
    private let onBytes: (_ sent: Int64, _ received: Int64) -> Void
    private let onFinish: () -> Void

    init(client: Int32, upstream: Int32,
         onBytes: @escaping (_ sent: Int64, _ received: Int64) -> Void,
         onFinish: @escaping () -> Void) {
        self.client = client
        self.upstream = upstream
        self.onBytes = onBytes
        self.onFinish = onFinish
    }

    func start() {
        let c = DispatchIO(type: .stream, fileDescriptor: client, queue: queue) { [client] _ in close(client) }
        let u = DispatchIO(type: .stream, fileDescriptor: upstream, queue: queue) { [upstream] _ in close(upstream) }
        c.setLimit(lowWater: 1)
        u.setLimit(lowWater: 1)
        clientIO = c
        upstreamIO = u
        pump(from: c, to: u, toFD: upstream, outgoing: true)
        pump(from: u, to: c, toFD: client, outgoing: false)
    }

    private func pump(from source: DispatchIO, to destination: DispatchIO, toFD: Int32, outgoing: Bool) {
        source.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, _ in
            if let data, !data.isEmpty {
                destination.write(offset: 0, data: data, queue: queue) { _, _, _ in }
                let count = Int64(data.count)
                outgoing ? onBytes(count, 0) : onBytes(0, count)
            }
            if done {
                // Half-close once everything queued has been written.
                destination.barrier { shutdown(toFD, SHUT_WR) }
                finishDirection()
            }
        }
    }

    private func finishDirection() {
        openDirections -= 1
        if openDirections == 0 {
            clientIO?.close()
            upstreamIO?.close()
            clientIO = nil
            upstreamIO = nil
            onFinish()
        }
    }
}
