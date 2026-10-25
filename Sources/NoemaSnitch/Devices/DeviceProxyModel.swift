import Darwin
import Foundation

/// State of the "Devices" section: the proxy for phones/tablets and what they send through it.
@MainActor
final class DeviceProxyModel: ObservableObject {
    struct Device: Identifiable, Hashable {
        let address: String
        var name: String?
        var requests = 0
        var sent: Int64 = 0
        var received: Int64 = 0
        var lastSeen = Date.distantPast
        var id: String { address }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var flows: [DeviceFlow] = []
    @Published private(set) var devices: [String: Device] = [:]
    @Published var error: String?
    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: Self.portKey) }
    }

    /// Called when the proxy starts, so Noema's own outgoing traffic can be allowed.
    var onStart: (() -> Void)?

    private let server = DeviceProxyServer()
    private var timer: Timer?
    private var index: [UUID: Int] = [:]
    private var pendingNames = Set<String>()
    private static let maxFlows = 5000
    private static let enabledKey = "deviceProxy.enabled"
    private static let portKey = "deviceProxy.port"

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        port = saved > 0 ? saved : 8888
        server.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                self?.error = message
                self?.stop()
            }
        }
        if UserDefaults.standard.bool(forKey: Self.enabledKey) && !Demo.isEnabled { start() }
    }

    var sortedDevices: [Device] {
        devices.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// IPv4 addresses of this Mac on the local network — what the phone should use.
    var macAddresses: [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return result }
        defer { freeifaddrs(list) }
        var cursor = list
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    func start() {
        error = nil
        do {
            try server.start(port: UInt16(clamping: port))
            isRunning = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            onStart?()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pull() }
            }
        } catch {
            self.error = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        server.stop()
        timer?.invalidate()
        timer = nil
        isRunning = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        pull()
    }

    func clear() {
        flows.removeAll()
        index.removeAll()
        devices.removeAll()
    }

    func loadDemo() {
        let now = Date()
        let samples: [(String, String, String, String?, Int?, Int64, Int64)] = [
            ("10.0.1.42", "CONNECT", "api.telegram.org", nil, nil, 4_200, 88_000),
            ("10.0.1.42", "CONNECT", "graph.instagram.com", nil, nil, 12_000, 1_900_000),
            ("10.0.1.42", "CONNECT", "gateway.icloud.com", nil, nil, 3_100, 9_400),
            ("10.0.1.42", "GET", "captive.apple.com", "/hotspot-detect.html", 200, 310, 520),
            ("10.0.1.42", "CONNECT", "app-measurement.com", nil, nil, 2_800, 900),
            ("10.0.1.57", "CONNECT", "www.youtube.com", nil, nil, 40_000, 9_800_000),
        ]
        let agents = ["Telegram/11.2 CFNetwork/1568 Darwin/24.0.0", "Instagram 352.0 (iPhone15,2; iOS 18_1)",
                      "com.apple.iCloudHelper/1.0 CFNetwork/1568 Darwin/24.0.0", "CaptiveNetworkSupport-491 wispr",
                      "Instagram/352 CFNetwork/1568 Darwin/24.0.0", "YouTube/19.42.1 CFNetwork/1568 Darwin/24.0.0"]
        for (i, s) in samples.enumerated() {
            var flow = DeviceFlow(id: UUID(), device: s.0, started: now.addingTimeInterval(Double(i - 30)), method: s.1,
                                  isHTTPS: s.1 == "CONNECT", host: s.2, port: s.1 == "CONNECT" ? 443 : 80,
                                  path: s.3, userAgent: agents[i])
            flow.status = s.4
            flow.sent = s.5
            flow.received = s.6
            flow.ended = flow.started.addingTimeInterval(Double(i) * 0.7 + 0.3)
            ingest(flow)
        }
        devices["10.0.1.42"]?.name = "iPhone-Eduard.lan"
        devices["10.0.1.57"]?.name = "iPad.lan"
        isRunning = true
    }

    private func pull() {
        for flow in server.drainChanges() { ingest(flow) }
    }

    private func ingest(_ flow: DeviceFlow) {
        if let i = index[flow.id] {
            let previous = flows[i]
            flows[i] = flow
            account(flow, previous: previous)
        } else {
            flows.insert(flow, at: 0)
            rebuildIndex()
            account(flow, previous: nil)
            if flows.count > Self.maxFlows {
                flows.removeLast(flows.count - Self.maxFlows)
                rebuildIndex()
            }
        }
    }

    private func account(_ flow: DeviceFlow, previous: DeviceFlow?) {
        var device = devices[flow.device] ?? Device(address: flow.device)
        if previous == nil { device.requests += 1 }
        device.sent += flow.sent - (previous?.sent ?? 0)
        device.received += flow.received - (previous?.received ?? 0)
        device.lastSeen = Date()
        devices[flow.device] = device
        if device.name == nil { resolveName(flow.device) }
    }

    private func rebuildIndex() {
        index = Dictionary(uniqueKeysWithValues: flows.enumerated().map { ($1.id, $0) })
    }

    /// Router-provided name (e.g. "iPhone-Eduard.lan") via reverse DNS.
    private func resolveName(_ address: String) {
        guard pendingNames.insert(address).inserted else { return }
        DispatchQueue.global(qos: .utility).async {
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST
            var res: UnsafeMutablePointer<addrinfo>?
            var name: String?
            if getaddrinfo(address, nil, &hints, &res) == 0, let info = res {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count),
                               nil, 0, NI_NAMEREQD) == 0 {
                    name = String(cString: host)
                }
                freeaddrinfo(res)
            }
            DispatchQueue.main.async {
                if let name { self.devices[address]?.name = name }
            }
        }
    }
}
