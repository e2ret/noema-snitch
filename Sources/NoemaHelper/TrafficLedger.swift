import Foundation
import NoemaShared

/// Counts bytes per app + host + port; drained once a second and sent to the app.
final class TrafficLedger {
    struct Key: Hashable {
        let executablePath: String
        let host: String?
        let ip: String
        let port: Int
    }

    private struct Entry {
        var appName: String
        var pid: Int32
        var sent: Int64 = 0
        var received: Int64 = 0
        var active = 0
        var dirty = true
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    func open(_ request: ConnectionRequest) -> Key {
        let key = Key(executablePath: request.executablePath, host: request.host,
                      ip: request.destination.ip, port: Int(request.destination.port))
        lock.lock()
        defer { lock.unlock() }
        var entry = entries[key] ?? Entry(appName: request.appName, pid: request.pid)
        entry.active += 1
        entry.pid = request.pid
        entry.dirty = true
        entries[key] = entry
        return key
    }

    func add(_ key: Key, sent: Int64 = 0, received: Int64 = 0) {
        lock.lock()
        defer { lock.unlock() }
        entries[key]?.sent += sent
        entries[key]?.received += received
        entries[key]?.dirty = true
    }

    func close(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }
        entries[key]?.active -= 1
        entries[key]?.dirty = true
    }

    /// Changes since the last call; forgets entries with no open connections.
    func drain() -> [TrafficEntry] {
        lock.lock()
        defer { lock.unlock() }
        var result: [TrafficEntry] = []
        for (key, entry) in entries where entry.dirty {
            result.append(TrafficEntry(
                executablePath: key.executablePath, appName: entry.appName, pid: entry.pid,
                host: key.host, ip: key.ip, port: key.port,
                sent: entry.sent, received: entry.received, active: max(entry.active, 0)
            ))
            if entry.active <= 0 {
                entries[key] = nil
            } else {
                entries[key]?.sent = 0
                entries[key]?.received = 0
                entries[key]?.dirty = false
            }
        }
        return result
    }
}
