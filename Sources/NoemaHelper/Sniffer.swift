import Darwin
import Foundation

/// Peeks (without consuming) at the first bytes a client sends to learn the
/// host name: TLS ClientHello SNI or the HTTP Host header.
enum Sniffer {
    static func host(fd: Int32, timeoutMs: Int32) -> String? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, MSG_PEEK)
        guard n > 0 else { return nil }
        let bytes = Array(buf[0..<n])
        return tlsServerName(bytes) ?? httpHost(bytes)
    }

    static func tlsServerName(_ b: [UInt8]) -> String? {
        // TLS record header (5) + handshake header (4).
        guard b.count > 9, b[0] == 0x16, b[5] == 0x01 else { return nil }
        var i = 9
        i += 2 + 32  // client version + random
        guard i < b.count else { return nil }
        i += 1 + Int(b[i])  // session id
        guard i + 2 <= b.count else { return nil }
        i += 2 + Int(u16(b, i))  // cipher suites
        guard i < b.count else { return nil }
        i += 1 + Int(b[i])  // compression methods
        guard i + 2 <= b.count else { return nil }
        let end = min(b.count, i + 2 + Int(u16(b, i)))
        i += 2
        while i + 4 <= end {
            let type = u16(b, i)
            let length = Int(u16(b, i + 2))
            i += 4
            if type == 0 {
                // server_name_list length (2), name type (1), name length (2), name.
                guard i + 5 <= end, b[i + 2] == 0 else { return nil }
                let nameLength = Int(u16(b, i + 3))
                let start = i + 5
                guard start + nameLength <= end else { return nil }
                return String(bytes: b[start..<start + nameLength], encoding: .ascii)?.lowercased()
            }
            i += length
        }
        return nil
    }

    static func httpHost(_ b: [UInt8]) -> String? {
        let methods = ["GET ", "POST ", "PUT ", "HEAD ", "DELETE ", "OPTIONS ", "PATCH ", "CONNECT "]
        let text = String(decoding: b, as: UTF8.self)
        guard methods.contains(where: text.hasPrefix) else { return nil }
        for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("host:") {
            var value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if !value.hasPrefix("["), let colon = value.lastIndex(of: ":") {
                value = String(value[..<colon])
            }
            return value.lowercased()
        }
        return nil
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }
}
