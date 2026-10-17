import Darwin
import Foundation

struct GeoCity: Hashable {
    let name: String
    let country: String
    let latitude: Double
    let longitude: Double
}

/// Offline IP → city lookup and land outlines, from Resources/Geo
/// (built by scripts/build-geodata.py; IP data by DB-IP, CC BY 4.0).
final class GeoDatabase: @unchecked Sendable {
    static let shared = GeoDatabase()

    private(set) var isLoaded = false
    private(set) var land: [[SIMD2<Float>]] = []
    private var cities: [GeoCity] = []
    private var v4Starts: [UInt32] = []
    private var v4City: [UInt32] = []
    private var v6Starts: [UInt64] = []
    private var v6City: [UInt32] = []
    private var cache: [String: GeoCity?] = [:]
    private let lock = NSLock()
    private static let unknown = UInt32.max

    /// Loads in the background; `completion` runs on the main queue.
    func loadIfNeeded(completion: @escaping @Sendable () -> Void) {
        guard !isLoaded else { return completion() }
        DispatchQueue.global(qos: .userInitiated).async {
            self.load()
            DispatchQueue.main.async(execute: completion)
        }
    }

    func city(for ip: String) -> GeoCity? {
        lock.lock()
        defer { lock.unlock() }
        guard isLoaded else { return nil }
        if let cached = cache[ip] { return cached }
        let result = lookup(ip)
        cache[ip] = result
        return result
    }

    private func lookup(_ ip: String) -> GeoCity? {
        var v4 = in_addr()
        var v6 = in6_addr()
        let index: UInt32?
        if inet_pton(AF_INET, ip, &v4) == 1 {
            index = Self.find(UInt32(bigEndian: v4.s_addr), in: v4Starts, v4City)
        } else if inet_pton(AF_INET6, ip, &v6) == 1 {
            let high = withUnsafeBytes(of: v6) { raw in
                raw.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            }
            index = Self.find(high, in: v6Starts, v6City)
        } else {
            index = nil
        }
        guard let index, index != Self.unknown, Int(index) < cities.count else { return nil }
        return cities[Int(index)]
    }

    /// Last range whose start is <= value.
    private static func find<T: Comparable>(_ value: T, in starts: [T], _ city: [UInt32]) -> UInt32? {
        var lo = 0
        var hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : city[lo - 1]
    }

    // MARK: - Loading

    private func load() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Geo") else { return }
        let landData = (try? Data(contentsOf: dir.appendingPathComponent("land.bin"))) ?? Data()
        let compressed = (try? Data(contentsOf: dir.appendingPathComponent("ipcity.bin.lzfse"))) ?? Data()
        let ipData = (try? (compressed as NSData).decompressed(using: .lzfse) as Data) ?? Data()

        var reader = Reader(data: landData)
        var polygons: [[SIMD2<Float>]] = []
        if let count = reader.u32() {
            for _ in 0..<count {
                guard let n = reader.u32() else { break }
                var ring: [SIMD2<Float>] = []
                ring.reserveCapacity(Int(n))
                for _ in 0..<n {
                    guard let lon = reader.f32(), let lat = reader.f32() else { break }
                    ring.append(SIMD2(lon, lat))
                }
                polygons.append(ring)
            }
        }

        var r = Reader(data: ipData)
        var cityList: [GeoCity] = []
        var s4: [UInt32] = [], c4: [UInt32] = [], s6: [UInt64] = [], c6: [UInt32] = []
        if r.bytes(8) == Array("NSGEO1\0\0".utf8), let count = r.u32() {
            cityList.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let lat = r.f32(), let lon = r.f32(), let cc = r.bytes(2), let len = r.u16(),
                      let name = r.bytes(Int(len)) else { break }
                cityList.append(GeoCity(name: String(decoding: name, as: UTF8.self),
                                        country: String(decoding: cc, as: UTF8.self),
                                        latitude: Double(lat), longitude: Double(lon)))
            }
            if let n = r.u32() {
                s4 = r.array(UInt32.self, count: Int(n))
                c4 = r.array(UInt32.self, count: Int(n))
            }
            if let n = r.u32() {
                s6 = r.array(UInt64.self, count: Int(n))
                c6 = r.array(UInt32.self, count: Int(n))
            }
        }

        lock.lock()
        land = polygons
        cities = cityList
        v4Starts = s4
        v4City = c4
        v6Starts = s6
        v6City = c6
        isLoaded = !cityList.isEmpty || !polygons.isEmpty
        lock.unlock()
    }

    private struct Reader {
        let data: Data
        var offset = 0

        init(data: Data) { self.data = data }

        mutating func bytes(_ n: Int) -> [UInt8]? {
            guard offset + n <= data.count else { return nil }
            defer { offset += n }
            return Array(data[data.startIndex + offset ..< data.startIndex + offset + n])
        }

        mutating func scalar<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }

        mutating func u16() -> UInt16? { scalar(UInt16.self) }
        mutating func u32() -> UInt32? { scalar(UInt32.self) }
        mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }

        mutating func array<T: FixedWidthInteger>(_ type: T.Type, count: Int) -> [T] {
            let size = MemoryLayout<T>.size * count
            guard offset + size <= data.count else { return [] }
            let result = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                data.withUnsafeBytes { raw in
                    let src = UnsafeRawBufferPointer(rebasing: raw[offset ..< offset + size])
                    UnsafeMutableRawBufferPointer(buffer).copyMemory(from: src)
                }
                initialized = count
            }
            offset += size
            return result.map { T(littleEndian: $0) }
        }
    }
}

/// Where this Mac is, from the time zone's coordinates in /usr/share/zoneinfo/zone.tab
/// (no network, no location permission).
enum HomeLocation {
    static let current: GeoCity = {
        let id = TimeZone.current.identifier
        let fallbackName = id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
        guard let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else {
            return GeoCity(name: fallbackName, country: "--", latitude: 55.75, longitude: 37.62)
        }
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let cols = line.split(separator: "\t")
            guard cols.count >= 3, cols[2] == id, let (lat, lon) = parse(String(cols[1])) else { continue }
            return GeoCity(name: fallbackName, country: String(cols[0]), latitude: lat, longitude: lon)
        }
        return GeoCity(name: fallbackName, country: "--", latitude: 55.75, longitude: 37.62)
    }()

    /// "+5545+03735" or "+404251-0740023" → degrees.
    private static func parse(_ s: String) -> (Double, Double)? {
        guard let split = s.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        func degrees(_ part: Substring, degreeDigits: Int) -> Double? {
            guard let sign = part.first else { return nil }
            let digits = part.dropFirst()
            guard digits.count >= degreeDigits + 2,
                  let d = Double(digits.prefix(degreeDigits)),
                  let m = Double(digits.dropFirst(degreeDigits).prefix(2)) else { return nil }
            let sec = Double(digits.dropFirst(degreeDigits + 2).prefix(2)) ?? 0
            let value = d + m / 60 + sec / 3600
            return sign == "-" ? -value : value
        }
        guard let lat = degrees(s[..<split], degreeDigits: 2),
              let lon = degrees(s[split...], degreeDigits: 3) else { return nil }
        return (lat, lon)
    }
}
