import Darwin
import Foundation

func log(_ message: String) {
    print("[\(ISO8601DateFormatter().string(from: Date()))] \(message)")
}

/// IPv4/IPv6 address + port with conversions to and from sockaddr.
struct SocketAddress: Hashable, CustomStringConvertible {
    var family: Int32
    /// 4 bytes for IPv4, 16 for IPv6.
    var bytes: [UInt8]
    var port: UInt16

    init?(storage: sockaddr_storage) {
        var ss = storage
        switch Int32(ss.ss_family) {
        case AF_INET:
            let sin = withUnsafePointer(to: &ss) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            }
            family = AF_INET
            bytes = withUnsafeBytes(of: sin.sin_addr) { Array($0) }
            port = UInt16(bigEndian: sin.sin_port)
        case AF_INET6:
            let sin6 = withUnsafePointer(to: &ss) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            }
            family = AF_INET6
            bytes = withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
            port = UInt16(bigEndian: sin6.sin6_port)
        default:
            return nil
        }
    }

    init?(ip: String, port: UInt16) {
        self.port = port
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            family = AF_INET
            bytes = withUnsafeBytes(of: v4) { Array($0) }
        } else if inet_pton(AF_INET6, ip, &v6) == 1 {
            family = AF_INET6
            bytes = withUnsafeBytes(of: v6) { Array($0) }
        } else {
            return nil
        }
    }

    init(family: Int32, bytes: [UInt8], port: UInt16) {
        self.family = family
        self.bytes = bytes
        self.port = port
    }

    var ip: String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        bytes.withUnsafeBytes { raw in
            _ = inet_ntop(family, raw.baseAddress, &buf, socklen_t(buf.count))
        }
        return String(cString: buf)
    }

    var description: String {
        family == AF_INET6 ? "[\(ip)]:\(port)" : "\(ip):\(port)"
    }

    var isLoopback: Bool {
        family == AF_INET ? bytes.first == 127 : bytes == [UInt8](repeating: 0, count: 15) + [1]
    }

    static func loopback(family: Int32, port: UInt16) -> SocketAddress {
        family == AF_INET6
            ? SocketAddress(family: AF_INET6, bytes: [UInt8](repeating: 0, count: 15) + [1], port: port)
            : SocketAddress(family: AF_INET, bytes: [127, 0, 0, 1], port: port)
    }

    func storage() -> (sockaddr_storage, socklen_t) {
        var ss = sockaddr_storage()
        if family == AF_INET {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &sin.sin_addr) { $0.copyBytes(from: bytes) }
            withUnsafeMutableBytes(of: &ss) { dst in
                withUnsafeBytes(of: sin) { dst.copyMemory(from: $0) }
            }
            return (ss, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        var sin6 = sockaddr_in6()
        sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sin6.sin6_family = sa_family_t(AF_INET6)
        sin6.sin6_port = port.bigEndian
        withUnsafeMutableBytes(of: &sin6.sin6_addr) { $0.copyBytes(from: bytes) }
        withUnsafeMutableBytes(of: &ss) { dst in
            withUnsafeBytes(of: sin6) { dst.copyMemory(from: $0) }
        }
        return (ss, socklen_t(MemoryLayout<sockaddr_in6>.size))
    }

    static func peer(of fd: Int32) -> SocketAddress? {
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let r = withUnsafeMutablePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
        }
        return r == 0 ? SocketAddress(storage: ss) : nil
    }

    static func local(of fd: Int32) -> SocketAddress? {
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let r = withUnsafeMutablePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return r == 0 ? SocketAddress(storage: ss) : nil
    }

    /// Addresses assigned to this Mac's interfaces.
    static func interfaceAddresses() -> Set<[UInt8]> {
        var result = Set<[UInt8]>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return result }
        defer { freeifaddrs(list) }
        var cursor = list
        while let ifa = cursor {
            if let sa = ifa.pointee.ifa_addr {
                var ss = sockaddr_storage()
                withUnsafeMutableBytes(of: &ss) { dst in
                    dst.copyMemory(from: UnsafeRawBufferPointer(start: sa, count: Int(sa.pointee.sa_len)))
                }
                if let addr = SocketAddress(storage: ss) { result.insert(addr.bytes) }
            }
            cursor = ifa.pointee.ifa_next
        }
        return result
    }
}
