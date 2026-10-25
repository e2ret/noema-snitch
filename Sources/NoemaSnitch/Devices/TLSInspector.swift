import Foundation

/// What the unencrypted TLS handshake reveals without any certificate:
/// the same data Charles shows on its "SSL" tab.
struct TLSInfo: Codable, Hashable {
    var sni: String?
    var clientVersions: [String] = []
    var clientCiphers: [String] = []
    var clientALPN: [String] = []
    var clientExtensions = 0
    var resumptionRequested = false
    var serverVersion: String?
    var serverCipher: String?
    var serverALPN: String?
    var serverExtensions = 0
    var resumed: Bool?
}

/// Collects the first bytes of each direction of a tunnel and parses the hellos.
struct TLSInspector {
    private var clientBuffer = Data()
    private var serverBuffer = Data()
    private(set) var clientDone = false
    private(set) var serverDone = false
    private var clientSessionID = Data()
    private static let limit = 20 * 1024

    var info = TLSInfo()

    /// Feeds client→server bytes; returns true when the ClientHello was just parsed.
    mutating func client(_ data: Data) -> Bool {
        guard !clientDone else { return false }
        clientBuffer.append(data)
        guard let body = Self.handshake(in: clientBuffer, type: 1) else {
            if clientBuffer.count > Self.limit || (clientBuffer.first.map { $0 != 0x16 } ?? false) { clientDone = true }
            return false
        }
        clientDone = true
        parseClientHello(body)
        clientBuffer = Data()
        return true
    }

    /// Feeds server→client bytes; returns true when the ServerHello was just parsed.
    mutating func server(_ data: Data) -> Bool {
        guard !serverDone else { return false }
        serverBuffer.append(data)
        guard let body = Self.handshake(in: serverBuffer, type: 2) else {
            if serverBuffer.count > Self.limit || (serverBuffer.first.map { $0 != 0x16 } ?? false) { serverDone = true }
            return false
        }
        serverDone = true
        parseServerHello(body)
        serverBuffer = Data()
        return true
    }

    /// Body of the first handshake message of `type` once enough records have arrived.
    private static func handshake(in data: Data, type: UInt8) -> [UInt8]? {
        let b = [UInt8](data)
        var payload: [UInt8] = []
        var i = 0
        while i + 5 <= b.count, b[i] == 0x16 {
            let length = Int(b[i + 3]) << 8 | Int(b[i + 4])
            guard i + 5 + length <= b.count else { break }
            payload += b[(i + 5)..<(i + 5 + length)]
            i += 5 + length
            if payload.count >= 4 {
                let hsLength = Int(payload[1]) << 16 | Int(payload[2]) << 8 | Int(payload[3])
                if payload.count >= 4 + hsLength {
                    return payload[0] == type ? Array(payload[4..<(4 + hsLength)]) : nil
                }
            }
        }
        return nil
    }

    private mutating func parseClientHello(_ b: [UInt8]) {
        var r = Reader(b)
        guard let legacy = r.u16() else { return }
        _ = r.skip(32)
        guard let sidLength = r.u8(), let sid = r.bytes(Int(sidLength)) else { return }
        clientSessionID = Data(sid)
        guard let cipherLength = r.u16(), let ciphers = r.bytes(Int(cipherLength)) else { return }
        info.clientCiphers = stride(from: 0, to: ciphers.count - 1, by: 2)
            .map { Self.cipherName(UInt16(ciphers[$0]) << 8 | UInt16(ciphers[$0 + 1])) }
        guard let compLength = r.u8(), r.skip(Int(compLength)) else { return }
        info.clientVersions = [Self.versionName(legacy)]
        guard let extLength = r.u16(), let exts = r.bytes(Int(extLength)) else { return }
        var e = Reader(exts)
        while let type = e.u16(), let length = e.u16(), let value = e.bytes(Int(length)) {
            info.clientExtensions += 1
            var v = Reader(value)
            switch type {
            case 0:  // server_name
                _ = v.u16()
                if v.u8() == 0, let n = v.u16(), let name = v.bytes(Int(n)) {
                    info.sni = String(bytes: name, encoding: .ascii)?.lowercased()
                }
            case 16:  // ALPN
                _ = v.u16()
                var list: [String] = []
                while let n = v.u8(), let p = v.bytes(Int(n)) { list.append(String(decoding: p, as: UTF8.self)) }
                info.clientALPN = list
            case 43:  // supported_versions
                if let n = v.u8(), let list = v.bytes(Int(n)) {
                    info.clientVersions = stride(from: 0, to: list.count - 1, by: 2)
                        .map { Self.versionName(UInt16(list[$0]) << 8 | UInt16(list[$0 + 1])) }
                }
            case 41:  // pre_shared_key
                info.resumptionRequested = true
            default:
                break
            }
        }
        if !clientSessionID.isEmpty && !info.clientVersions.contains("TLSv1.3") { info.resumptionRequested = true }
    }

    private mutating func parseServerHello(_ b: [UInt8]) {
        var r = Reader(b)
        guard let legacy = r.u16() else { return }
        _ = r.skip(32)
        guard let sidLength = r.u8(), let sid = r.bytes(Int(sidLength)),
              let cipher = r.u16(), r.skip(1) else { return }
        info.serverVersion = Self.versionName(legacy)
        info.serverCipher = Self.cipherName(cipher)
        var pskAccepted = false
        if let extLength = r.u16(), let exts = r.bytes(Int(extLength)) {
            var e = Reader(exts)
            while let type = e.u16(), let length = e.u16(), let value = e.bytes(Int(length)) {
                info.serverExtensions += 1
                var v = Reader(value)
                switch type {
                case 43: if let ver = v.u16() { info.serverVersion = Self.versionName(ver) }
                case 41: pskAccepted = true
                case 16:
                    _ = v.u16()
                    if let n = v.u8(), let p = v.bytes(Int(n)) { info.serverALPN = String(decoding: p, as: UTF8.self) }
                default: break
                }
            }
        }
        if info.serverVersion == "TLSv1.3" {
            info.resumed = pskAccepted
        } else {
            info.resumed = !sid.isEmpty && Data(sid) == clientSessionID
        }
    }

    static func versionName(_ v: UInt16) -> String {
        switch v {
        case 0x0304: "TLSv1.3"
        case 0x0303: "TLSv1.2"
        case 0x0302: "TLSv1.1"
        case 0x0301: "TLSv1.0"
        case 0x0300: "SSLv3"
        case _ where v & 0x0f0f == 0x0a0a: "GREASE"
        default: String(format: "0x%04x", v)
        }
    }

    private static let ciphers: [UInt16: String] = [
        0x1301: "TLS_AES_128_GCM_SHA256", 0x1302: "TLS_AES_256_GCM_SHA384",
        0x1303: "TLS_CHACHA20_POLY1305_SHA256", 0x1304: "TLS_AES_128_CCM_SHA256",
        0xc02b: "ECDHE_ECDSA_AES_128_GCM_SHA256", 0xc02c: "ECDHE_ECDSA_AES_256_GCM_SHA384",
        0xc02f: "ECDHE_RSA_AES_128_GCM_SHA256", 0xc030: "ECDHE_RSA_AES_256_GCM_SHA384",
        0xcca8: "ECDHE_RSA_CHACHA20_POLY1305", 0xcca9: "ECDHE_ECDSA_CHACHA20_POLY1305",
        0xc009: "ECDHE_ECDSA_AES_128_CBC_SHA", 0xc00a: "ECDHE_ECDSA_AES_256_CBC_SHA",
        0xc013: "ECDHE_RSA_AES_128_CBC_SHA", 0xc014: "ECDHE_RSA_AES_256_CBC_SHA",
        0x009c: "RSA_AES_128_GCM_SHA256", 0x009d: "RSA_AES_256_GCM_SHA384",
        0x002f: "RSA_AES_128_CBC_SHA", 0x0035: "RSA_AES_256_CBC_SHA",
        0x00ff: "EMPTY_RENEGOTIATION_INFO",
    ]

    static func cipherName(_ c: UInt16) -> String {
        if c & 0x0f0f == 0x0a0a { return "GREASE" }
        return ciphers[c] ?? String(format: "0x%04x", c)
    }

    private struct Reader {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }
        mutating func u8() -> UInt8? { guard i < b.count else { return nil }; defer { i += 1 }; return b[i] }
        mutating func u16() -> UInt16? {
            guard i + 2 <= b.count else { return nil }
            defer { i += 2 }
            return UInt16(b[i]) << 8 | UInt16(b[i + 1])
        }
        mutating func bytes(_ n: Int) -> [UInt8]? {
            guard n >= 0, i + n <= b.count else { return nil }
            defer { i += n }
            return Array(b[i..<(i + n)])
        }
        mutating func skip(_ n: Int) -> Bool { bytes(n) != nil }
    }
}
