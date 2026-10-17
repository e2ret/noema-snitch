import Darwin
import Foundation

/// Loads the redirect rules into a pf anchor and looks up original destinations.
///
/// Outgoing TCP from every process except ours (marked by our group id) is
/// routed to lo0 and redirected to the proxy, the technique mitmproxy uses for
/// transparent mode on macOS. The anchor hangs under "com.apple/*", which the
/// stock /etc/pf.conf already references, so no system file is edited.
final class PFController {
    static let anchor = "com.apple/noemasnitch"

    let proxyPort: UInt16
    let groupID: gid_t
    private var enableToken: String?
    private var devFD: Int32 = -1
    private let lock = NSLock()

    init(proxyPort: UInt16, groupID: gid_t) {
        self.proxyPort = proxyPort
        self.groupID = groupID
    }

    func install(blockQUIC: Bool) {
        var rules = """
        rdr pass on lo0 inet proto tcp from any to ! 127.0.0.0/8 -> 127.0.0.1 port \(proxyPort)
        rdr pass on lo0 inet6 proto tcp from any to ! ::1 -> ::1 port \(proxyPort)
        pass out quick on ! lo0 route-to (lo0 127.0.0.1) inet proto tcp from any to any group != \(groupID) keep state
        pass out quick on ! lo0 route-to (lo0 ::1) inet6 proto tcp from any to any group != \(groupID) keep state

        """
        if blockQUIC {
            rules += "block drop out quick on ! lo0 proto udp from any to any port 443 group != \(groupID)\n"
        }
        let (status, output) = Self.pfctl(["-a", Self.anchor, "-f", "-"], input: rules)
        log("pf rules loaded (status \(status)) \(output)")

        if enableToken == nil {
            let (_, out) = Self.pfctl(["-E"])
            enableToken = out.range(of: #"Token : (\d+)"#, options: .regularExpression)
                .map { String(out[$0]).components(separatedBy: " : ").last ?? "" }
            log("pf enabled, token \(enableToken ?? "?")")
        }
    }

    func uninstall() {
        Self.pfctl(["-a", Self.anchor, "-F", "all"])
        if let token = enableToken {
            Self.pfctl(["-X", token])
            enableToken = nil
        }
        log("pf rules removed")
    }

    /// Where the client originally wanted to connect before pf redirected it to us.
    func originalDestination(peer: SocketAddress, local: SocketAddress) -> SocketAddress? {
        for direction in [PF_OUT, PF_IN] {
            if let dst = natLookup(peer: peer, local: local, direction: direction),
               !(dst.isLoopback && dst.port == proxyPort) {
                return dst
            }
        }
        return stateTableLookup(peer: peer)
    }

    // MARK: - DIOCNATLOOK

    private let PF_IN: UInt8 = 1
    private let PF_OUT: UInt8 = 2
    /// _IOWR('D', 23, struct pfioc_natlook) with sizeof == 84 on XNU.
    private static let DIOCNATLOOK: UInt = 0xC054_4417

    /// Mirror of XNU's struct pfioc_natlook (bsd/net/pfvar.h).
    private struct PFNatLook {
        typealias Addr = (UInt32, UInt32, UInt32, UInt32)
        var saddr: Addr = (0, 0, 0, 0)
        var daddr: Addr = (0, 0, 0, 0)
        var rsaddr: Addr = (0, 0, 0, 0)
        var rdaddr: Addr = (0, 0, 0, 0)
        var sxport: UInt32 = 0
        var dxport: UInt32 = 0
        var rsxport: UInt32 = 0
        var rdxport: UInt32 = 0
        var af: UInt8 = 0
        var proto: UInt8 = 0
        var protoVariant: UInt8 = 0
        var direction: UInt8 = 0
    }

    private func natLookup(peer: SocketAddress, local: SocketAddress, direction: UInt8) -> SocketAddress? {
        lock.lock()
        defer { lock.unlock() }
        if devFD < 0 { devFD = open("/dev/pf", O_RDWR) }
        guard devFD >= 0, MemoryLayout<PFNatLook>.size == 84 else { return nil }

        var nl = PFNatLook()
        withUnsafeMutableBytes(of: &nl.saddr) { $0.copyBytes(from: peer.bytes) }
        withUnsafeMutableBytes(of: &nl.daddr) { $0.copyBytes(from: local.bytes) }
        withUnsafeMutableBytes(of: &nl.sxport) { $0.storeBytes(of: peer.port.bigEndian, as: UInt16.self) }
        withUnsafeMutableBytes(of: &nl.dxport) { $0.storeBytes(of: local.port.bigEndian, as: UInt16.self) }
        nl.af = UInt8(peer.family)
        nl.proto = UInt8(IPPROTO_TCP)
        nl.direction = direction

        guard ioctl(devFD, Self.DIOCNATLOOK, &nl) == 0 else { return nil }
        let count = peer.family == AF_INET ? 4 : 16
        let bytes = withUnsafeBytes(of: nl.rdaddr) { Array($0.prefix(count)) }
        let port = withUnsafeBytes(of: nl.rdxport) { UInt16(bigEndian: $0.load(as: UInt16.self)) }
        guard port != 0, bytes.contains(where: { $0 != 0 }) else { return nil }
        return SocketAddress(family: peer.family, bytes: bytes, port: port)
    }

    // MARK: - Fallback: parse `pfctl -s state`

    /// Lines look like `ALL tcp 127.0.0.1:47900 (1.2.3.4:443) <- 192.168.1.5:61234 ...`
    /// (IPv6 uses `addr[port]`).
    private func stateTableLookup(peer: SocketAddress) -> SocketAddress? {
        let needle = peer.family == AF_INET6 ? "<- \(peer.ip)[\(peer.port)]" : "<- \(peer.ip):\(peer.port)"
        let (_, out) = Self.pfctl(["-s", "state"])
        for line in out.split(separator: "\n") where line.contains(needle) {
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close else { continue }
            let inner = String(line[line.index(after: open)..<close])
            if let bracket = inner.lastIndex(of: "["), inner.hasSuffix("]") {
                let ip = String(inner[..<bracket])
                let port = UInt16(inner[inner.index(after: bracket)..<inner.index(before: inner.endIndex)])
                if let port, let addr = SocketAddress(ip: ip, port: port) { return addr }
            } else if let colon = inner.lastIndex(of: ":") {
                let port = UInt16(inner[inner.index(after: colon)...])
                if let port, let addr = SocketAddress(ip: String(inner[..<colon]), port: port) { return addr }
            }
        }
        return nil
    }

    @discardableResult
    static func pfctl(_ args: [String], input: String? = nil) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        let inPipe = Pipe()
        if input != nil { process.standardInput = inPipe }
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
