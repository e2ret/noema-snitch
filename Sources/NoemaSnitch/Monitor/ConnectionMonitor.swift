import Foundation
import NoemaShared

@MainActor
final class ConnectionMonitor: ObservableObject {
    @Published private(set) var connections: [Connection] = []
    @Published private(set) var hostnames: [String: String] = [:]
    /// Executables seen for the first time since the user last cleared the list.
    @Published private(set) var newApps: Set<String> = []
    @Published private(set) var lastUpdate: Date?
    @Published var isPaused = false {
        didSet { if !isPaused { refresh() } }
    }

    private var knownApps: Set<String>
    private var timer: Timer?
    private var pendingLookups = Set<String>()
    private var scanning = false
    private let dnsQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        return q
    }()

    private static let knownAppsKey = "knownApps"

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.knownAppsKey)
        knownApps = Set(stored ?? [])
        // On first launch everything already running counts as known.
        firstRun = stored == nil
        restart()
    }

    private var firstRun: Bool

    var interval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "refreshInterval")
        return v > 0 ? v : 2
    }

    func restart() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard !isPaused, !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let result = SocketScanner.scan()
            DispatchQueue.main.async { [weak self] in
                self?.apply(result)
            }
        }
    }

    func hostname(for address: String) -> String {
        hostnames[address] ?? address
    }

    func forgetNewApps() {
        newApps.removeAll()
    }

    private func apply(_ result: [Connection]) {
        scanning = false
        connections = result.sorted {
            ($0.displayName.localizedLowercase, $0.remoteAddress, $0.remotePort)
                < ($1.displayName.localizedLowercase, $1.remoteAddress, $1.remotePort)
        }
        lastUpdate = Date()

        let seen = Set(result.map(\.executablePath)).subtracting([""])
        let unseen = seen.subtracting(knownApps)
        if !unseen.isEmpty {
            if !firstRun { newApps.formUnion(unseen) }
            knownApps.formUnion(unseen)
            UserDefaults.standard.set(Array(knownApps), forKey: Self.knownAppsKey)
        }
        firstRun = false

        if UserDefaults.standard.object(forKey: "resolveHostnames") as? Bool ?? true {
            for address in Set(result.map(\.remoteAddress)) where hostnames[address] == nil {
                lookup(address)
            }
        }
    }

    private func lookup(_ address: String) {
        guard pendingLookups.insert(address).inserted else { return }
        dnsQueue.addOperation {
            let name = Self.reverseDNS(address)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingLookups.remove(address)
                // Store the address itself on failure so we don't retry forever.
                self.hostnames[address] = name ?? address
            }
        }
    }

    nonisolated private static func reverseDNS(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                          &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        return String(cString: host)
    }
}
