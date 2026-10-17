import AppKit
import NoemaShared
import SwiftUI

/// One place on the globe the Mac talks to.
struct GlobeDestination: Identifiable {
    let city: GeoCity
    var bytes: Int64
    var denied: Bool
    var active: Int
    var id: String { city.country + "|" + city.name }
}

/// Camera state, mutated by the AppKit event view and read every frame.
final class GlobeCamera {
    var yaw: Double     // longitude at the center, degrees
    var pitch: Double   // latitude at the center, degrees
    var zoom: Double = 1
    /// Always spins slowly; paused only while the mouse button holds the globe.
    var isDragging = false
    var lastFrame = Date()

    init(center: GeoCity) {
        yaw = center.longitude
        pitch = max(-60, min(60, center.latitude * 0.7))
    }
}

/// Rotating 3D globe with connection arcs from this Mac, like the MetaCubeX dashboard:
/// spins slowly on its own, drag to rotate, scroll or pinch to zoom.
struct GlobeView: View {
    @EnvironmentObject private var model: NetworkModel
    @State private var camera = GlobeCamera(center: HomeLocation.current)
    @State private var geoReady = GeoDatabase.shared.isLoaded
    private let home = HomeLocation.current

    var body: some View {
        let _ = model.revision
        let destinations = geoReady ? Self.destinations(from: model) : []
        ZStack(alignment: .bottomTrailing) {
            TimelineView(.animation(minimumInterval: 1.0 / 40)) { context in
                Canvas { ctx, size in
                    advance(to: context.date)
                    GlobeRenderer(camera: camera, size: size, home: home,
                                  land: GeoDatabase.shared.land, time: context.date.timeIntervalSinceReferenceDate)
                        .draw(in: &ctx, destinations: destinations)
                }
            }
            GlobeInteraction(camera: camera)

            Link(destination: URL(string: "https://db-ip.com")!) {
                Text(verbatim: "IP data by DB-IP").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if !geoReady { ProgressView().controlSize(.small) }
        }
        .onAppear {
            GeoDatabase.shared.loadIfNeeded { geoReady = true }
        }
    }

    private func advance(to date: Date) {
        let dt = min(0.1, date.timeIntervalSince(camera.lastFrame))
        camera.lastFrame = date
        if !camera.isDragging {
            camera.yaw += dt * 6
        }
    }

    @MainActor
    static func destinations(from model: NetworkModel) -> [GlobeDestination] {
        var byCity: [String: GlobeDestination] = [:]
        for app in model.apps.values {
            for domain in app.domains.values {
                for host in domain.hosts.values {
                    for ip in host.ips {
                        guard let city = GeoDatabase.shared.city(for: ip) else { continue }
                        let key = city.country + "|" + city.name
                        var d = byCity[key] ?? GlobeDestination(city: city, bytes: 0, denied: false, active: 0)
                        d.bytes += host.totalSent + host.totalReceived
                        d.denied = d.denied || host.denied > 0
                        d.active += host.active
                        byCity[key] = d
                    }
                }
            }
        }
        return byCity.values.sorted { $0.bytes > $1.bytes }
    }
}

private struct GlobeRenderer {
    let camera: GlobeCamera
    let size: CGSize
    let home: GeoCity
    let land: [[SIMD2<Float>]]
    let time: Double

    private var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    private var radius: CGFloat { min(size.width, size.height) * 0.4 * camera.zoom }

    private static let ocean = Color(red: 0.86, green: 0.90, blue: 0.95)
    private static let landFill = Color(red: 0.39, green: 0.47, blue: 0.57)
    private static let arc = Color(red: 0.40, green: 0.72, blue: 1.0)
    private static let arcDenied = Color(red: 1.0, green: 0.58, blue: 0.30)
    private static let homeColor = Color(red: 1.0, green: 0.55, blue: 0.25)

    /// Orthographic projection; z > 0 is the visible hemisphere.
    private func project(lat: Double, lon: Double, altitude: Double = 0) -> SIMD3<Double> {
        let φ = lat * .pi / 180, λ = (lon - camera.yaw) * .pi / 180, φ0 = camera.pitch * .pi / 180
        let x = cos(φ) * sin(λ)
        let y = cos(φ0) * sin(φ) - sin(φ0) * cos(φ) * cos(λ)
        let z = sin(φ0) * sin(φ) + cos(φ0) * cos(φ) * cos(λ)
        return SIMD3(x, y, z) * (1 + altitude)
    }

    private func screen(_ v: SIMD3<Double>) -> CGPoint {
        CGPoint(x: center.x + radius * v.x, y: center.y - radius * v.y)
    }

    func draw(in ctx: inout GraphicsContext, destinations: [GlobeDestination]) {
        let disk = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.18), radius: 18, y: 8))
            layer.fill(disk, with: .color(Self.ocean))
        }

        // Land: rings are clipped at the horizon and closed along the rim.
        var landPath = Path()
        for ring in land {
            landPath.addPath(clippedRing(ring))
        }
        ctx.drawLayer { layer in
            layer.clip(to: disk)
            layer.fill(landPath, with: .color(Self.landFill))
            // Soft light from the top-left.
            layer.fill(disk, with: .radialGradient(
                Gradient(colors: [.white.opacity(0.22), .clear]),
                center: CGPoint(x: center.x - radius * 0.4, y: center.y - radius * 0.45),
                startRadius: 0, endRadius: radius * 1.3))
        }
        ctx.stroke(disk, with: .color(.black.opacity(0.08)), lineWidth: 1)

        // Arcs from home to every destination.
        let h = unit(lat: home.latitude, lon: home.longitude)
        let maxBytes = Double(max(destinations.first?.bytes ?? 1, 1))
        var labelCandidates: [(CGPoint, String, Bool, Double)] = []
        for (i, d) in destinations.prefix(60).enumerated() {
            let t = unit(lat: d.city.latitude, lon: d.city.longitude)
            let angle = acos(max(-1, min(1, (h * t).sum())))
            guard angle > 0.002 else { continue }
            let lift = 0.06 + 0.5 * angle / .pi
            let color = d.denied ? Self.arcDenied : Self.arc
            let weight = 1.6 + 1.8 * log10(1 + 9 * Double(d.bytes) / maxBytes)
            let steps = 48
            var points: [(CGPoint, Bool)] = []
            for s in 0...steps {
                let f = Double(s) / Double(steps)
                let v = slerp(h, t, angle, f)
                let lat = asin(v.z) * 180 / .pi
                let lon = atan2(v.y, v.x) * 180 / .pi
                let p = project(lat: lat, lon: lon, altitude: lift * sin(.pi * f))
                let visible = p.z > 0 || p.x * p.x + p.y * p.y > 1
                points.append((screen(p), visible))
            }
            strokeVisible(points, in: &ctx, color: color.opacity(0.75), width: weight)

            // A brighter comet travelling along the arc.
            let phase = (time * 0.35 + Double(i) * 0.137).truncatingRemainder(dividingBy: 1)
            let head = Int(phase * Double(steps))
            let tail = max(0, head - 8)
            if head > tail {
                strokeVisible(Array(points[tail...head]), in: &ctx, color: color, width: weight + 1)
            }

            let endpoint = project(lat: d.city.latitude, lon: d.city.longitude)
            if endpoint.z > 0 {
                let p = screen(endpoint)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(color))
                labelCandidates.append((p, d.city.name, d.denied, Double(d.bytes)))
            }
        }

        // Home marker with a pulse.
        let homeV = project(lat: home.latitude, lon: home.longitude)
        if homeV.z > 0 {
            let p = screen(homeV)
            let pulse = (time.truncatingRemainder(dividingBy: 2)) / 2
            let r = 4 + 10 * pulse
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                       with: .color(Self.homeColor.opacity(1 - pulse)), lineWidth: 1.5)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(Self.homeColor))
            labelCandidates.insert((p, home.name, false, .infinity), at: 0)
        }

        drawLabels(labelCandidates, in: &ctx)
    }

    /// Visible part of a land ring; hidden stretches are replaced by an arc along the rim.
    private func clippedRing(_ ring: [SIMD2<Float>]) -> Path {
        let points = ring.map { project(lat: Double($0.y), lon: Double($0.x)) }
        guard let start = points.firstIndex(where: { $0.z > 0 }) else { return Path() }
        var path = Path()
        var exitAngle: Double?
        var started = false
        let n = points.count
        for k in 0...n {
            let cur = points[(start + k) % n]
            let prev = points[(start + k - 1 + n) % n]
            if cur.z > 0 {
                if k > 0, prev.z <= 0 {
                    let entry = horizon(prev, cur)
                    if let exitAngle { addRim(&path, from: exitAngle, to: atan2(entry.y, entry.x)) }
                    path.addLine(to: screen(entry))
                    exitAngle = nil
                }
                if started { path.addLine(to: screen(cur)) } else { path.move(to: screen(cur)); started = true }
            } else if prev.z > 0 {
                let exit = horizon(prev, cur)
                path.addLine(to: screen(exit))
                exitAngle = atan2(exit.y, exit.x)
            }
        }
        path.closeSubpath()
        return path
    }

    /// Point where the segment a→b crosses z = 0, pushed onto the unit circle.
    private func horizon(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        let t = a.z / (a.z - b.z)
        let p = a + (b - a) * t
        let len = max(1e-9, (p.x * p.x + p.y * p.y).squareRoot())
        return SIMD3(p.x / len, p.y / len, 0)
    }

    /// Arc along the rim the short way round, in screen space.
    private func addRim(_ path: inout Path, from a: Double, to b: Double) {
        var delta = b - a
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        let steps = max(2, Int(abs(delta) / 0.08))
        for i in 1...steps {
            let angle = a + delta * Double(i) / Double(steps)
            path.addLine(to: screen(SIMD3(cos(angle), sin(angle), 0)))
        }
    }

    private func strokeVisible(_ points: [(CGPoint, Bool)], in ctx: inout GraphicsContext, color: Color, width: CGFloat) {
        var path = Path()
        var drawing = false
        for (p, visible) in points {
            if visible {
                if drawing { path.addLine(to: p) } else { path.move(to: p); drawing = true }
            } else {
                drawing = false
            }
        }
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    /// White rounded "pills" like the dashboard; skips labels that would overlap.
    private func drawLabels(_ candidates: [(CGPoint, String, Bool, Double)], in ctx: inout GraphicsContext) {
        var placed: [CGRect] = []
        for (point, name, _, _) in candidates.prefix(14) {
            let text = ctx.resolve(Text(verbatim: name).font(.system(size: 13, weight: .medium)).foregroundColor(.black.opacity(0.85)))
            let ts = text.measure(in: CGSize(width: 300, height: 40))
            let rect = CGRect(x: point.x - ts.width / 2 - 10, y: point.y - ts.height - 22,
                              width: ts.width + 20, height: ts.height + 10)
            guard !placed.contains(where: { $0.insetBy(dx: -4, dy: -2).intersects(rect) }) else { continue }
            placed.append(rect)
            let pill = Path(roundedRect: rect, cornerRadius: 8)
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.18), radius: 3, y: 1))
                layer.fill(pill, with: .color(.white.opacity(0.95)))
            }
            ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    private func unit(lat: Double, lon: Double) -> SIMD3<Double> {
        let φ = lat * .pi / 180, λ = lon * .pi / 180
        return SIMD3(cos(φ) * cos(λ), cos(φ) * sin(λ), sin(φ))
    }

    private func slerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ angle: Double, _ f: Double) -> SIMD3<Double> {
        let s = sin(angle)
        return a * (sin((1 - f) * angle) / s) + b * (sin(f * angle) / s)
    }
}

/// Mouse drag rotates, scroll wheel / pinch zooms.
private struct GlobeInteraction: NSViewRepresentable {
    let camera: GlobeCamera

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.camera = camera
        return view
    }

    func updateNSView(_ view: EventView, context: Context) {
        view.camera = camera
    }

    final class EventView: NSView {
        var camera: GlobeCamera?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            NSCursor.closedHand.push()
            camera?.isDragging = true
        }

        override func mouseUp(with event: NSEvent) {
            NSCursor.pop()
            camera?.isDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let camera else { return }
            let speed = 0.35 / camera.zoom
            camera.yaw -= Double(event.deltaX) * speed
            camera.pitch = max(-85, min(85, camera.pitch + Double(event.deltaY) * speed))
        }

        override func scrollWheel(with event: NSEvent) {
            guard let camera else { return }
            let delta = event.hasPreciseScrollingDeltas ? Double(event.scrollingDeltaY) * 0.01 : Double(event.scrollingDeltaY) * 0.1
            camera.zoom = max(0.6, min(8, camera.zoom * exp(delta)))
        }

        override func magnify(with event: NSEvent) {
            guard let camera else { return }
            camera.zoom = max(0.6, min(8, camera.zoom * (1 + Double(event.magnification))))
        }
    }
}
