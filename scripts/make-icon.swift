// Draws the Noema Snitch app icon (1024×1024 PNG) with Core Graphics.
// Usage: scripts/make-icon.sh  (renders, scales and packs Resources/AppIcon.icns)
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824×824 body with a 100 px margin.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x000000, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x16224A))
ctx.fillPath()
ctx.restoreGState()

// Background: deep indigo to teal.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [color(0x0F8A8C), color(0x1A2E63), color(0x161E45)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 200, y: 100), end: CGPoint(x: 820, y: 924), options: [])
// Soft glow behind the globe.
let glow = CGGradient(colorsSpace: space, colors: [color(0x7FD3FF, 0.35), color(0x7FD3FF, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 500, y: 500), startRadius: 0,
                       endCenter: CGPoint(x: 500, y: 500), endRadius: 420, options: [])
ctx.restoreGState()

// Globe.
let center = CGPoint(x: 492, y: 476)
let r: CGFloat = 268
let globe = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.35))
ctx.addEllipse(in: globe)
ctx.setFillColor(color(0xDCE6F0))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addEllipse(in: globe)
ctx.clip()
let sphere = CGGradient(colorsSpace: space, colors: [color(0xF3F7FB), color(0xC3D3E5), color(0x8EA6C2)] as CFArray,
                        locations: [0, 0.6, 1])!
ctx.drawRadialGradient(sphere, startCenter: CGPoint(x: center.x - r * 0.35, y: center.y + r * 0.4), startRadius: 0,
                       endCenter: center, endRadius: r * 1.05, options: [.drawsAfterEndLocation])
// Graticule: meridians as ellipses, parallels as chords; tilted slightly.
ctx.translateBy(x: center.x, y: center.y)
ctx.rotate(by: -0.28)
ctx.setStrokeColor(color(0x5E7189, 0.55))
ctx.setLineWidth(9)
for k in [0.25, 0.62, 0.9] as [CGFloat] {
    ctx.strokeEllipse(in: CGRect(x: -r * k, y: -r, width: r * 2 * k, height: r * 2))
}
ctx.move(to: CGPoint(x: 0, y: -r)); ctx.addLine(to: CGPoint(x: 0, y: r)); ctx.strokePath()
for lat in [-0.62, -0.22, 0.22, 0.62] as [CGFloat] {
    let y = r * lat
    let half = (r * r - y * y).squareRoot()
    ctx.move(to: CGPoint(x: -half, y: y)); ctx.addLine(to: CGPoint(x: half, y: y)); ctx.strokePath()
}
ctx.restoreGState()
ctx.addEllipse(in: globe)
ctx.setStrokeColor(color(0xFFFFFF, 0.5))
ctx.setLineWidth(4)
ctx.strokePath()

// Connection arcs from "this Mac" rising off the globe, sent → received colours.
let home = CGPoint(x: 400, y: 380)
func arc(to end: CGPoint, control: CGPoint, colors: [CGColor], width: CGFloat) {
    let path = CGMutablePath()
    path.move(to: home)
    path.addQuadCurve(to: end, control: control)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: colors.last!.copy(alpha: 0.6))
    ctx.addPath(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1))
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: home, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.setFillColor(colors.last!)
    ctx.fillEllipse(in: CGRect(x: end.x - 20, y: end.y - 20, width: 40, height: 40))
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(7)
    ctx.strokeEllipse(in: CGRect(x: end.x - 20, y: end.y - 20, width: 40, height: 40))
}
arc(to: CGPoint(x: 772, y: 742), control: CGPoint(x: 470, y: 900), colors: [color(0xDB6BF0), color(0x2A8CF5)], width: 30)
arc(to: CGPoint(x: 808, y: 430), control: CGPoint(x: 640, y: 640), colors: [color(0xDB6BF0), color(0x52C7FF)], width: 22)

// This Mac.
ctx.setFillColor(color(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: home.x - 36, y: home.y - 36, width: 72, height: 72))
ctx.setFillColor(color(0xFF8A3D))
ctx.fillEllipse(in: CGRect(x: home.x - 24, y: home.y - 24, width: 48, height: 48))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
