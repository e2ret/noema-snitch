import Darwin
import Foundation
import NoemaShared

/// Unix-socket server the app connects to for prompts, rules and events.
/// Only root and the user logged in at the console may connect.
final class IPCServer {
    private let engine: DecisionEngine
    private let queue = DispatchQueue(label: "noema.ipc")
    private var clients: [ObjectIdentifier: LineChannel] = [:]
    private var listenSource: DispatchSourceRead?
    private let clientCount = NSLock()
    private var count = 0

    init(engine: DecisionEngine) {
        self.engine = engine
    }

    var hasClients: Bool {
        clientCount.lock()
        defer { clientCount.unlock() }
        return count > 0
    }

    func start() throws {
        guard let fd = UnixSocket.listen(path: IPC.socketPath) else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        chmod(IPC.socketPath, 0o666)  // access is checked per peer in accept
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0, let self else { return }
            guard self.isAllowedPeer(client) else {
                log("rejected IPC client")
                close(client)
                return
            }
            self.attach(client)
        }
        source.resume()
        listenSource = source
        log("IPC listening on \(IPC.socketPath)")
    }

    func broadcast(_ message: HelperMessage) {
        guard let data = IPC.encode(message) else { return }
        queue.async { [self] in
            clients.values.forEach { $0.send(data: data) }
        }
    }

    private func attach(_ fd: Int32) {
        let channel = LineChannel(fd: fd, queue: queue)
        let id = ObjectIdentifier(channel)
        channel.onLine = { [weak self, weak channel] data in
            guard let self, let channel, let message = IPC.decode(ClientMessage.self, from: data) else { return }
            self.handle(message, from: channel)
        }
        channel.onClose = { [weak self] in
            self?.clients[id] = nil
            self?.setCount(self?.clients.count ?? 0)
        }
        clients[id] = channel
        setCount(clients.count)
        channel.start()
    }

    private func handle(_ message: ClientMessage, from channel: LineChannel) {
        switch message {
        case .hello:
            engine.snapshot { settings, rules, prompts in
                channel.send(HelperMessage.hello(version: IPC.version, settings: settings))
                channel.send(HelperMessage.rules(rules))
                prompts.forEach { channel.send(HelperMessage.prompt($0)) }
            }
        case .verdict(let verdict):
            engine.apply(verdict)
        case .upsertRule(let rule):
            engine.upsert(rule)
        case .deleteRules(let ids):
            engine.delete(ids)
        case .setSettings(let settings):
            engine.update(settings)
        }
    }

    private func setCount(_ value: Int) {
        clientCount.lock()
        count = value
        clientCount.unlock()
    }

    private func isAllowedPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        var console = stat()
        guard stat("/dev/console", &console) == 0 else { return uid == 0 }
        return uid == 0 || uid == console.st_uid
    }
}
