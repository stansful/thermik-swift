// render-icon.swift — Thermik (MIT). Unit 8 tool: renders the app icon PNGs from the vector concept of
// research/design/icon/thermik-icon.svg (DES §7.2 / SPEC §4.15) directly with Core Graphics at every size, so small
// renditions stay crisp. Additions over the SVG draft: Apple-style continuous corners, the standard
// macOS icon drop shadow, a faint top highlight.
// Usage (regenerates every AppIcon rendition in place):
//   swift scripts/lib/render-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics
import SwiftUI

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Apple's continuous-corner ("squircle") rounded rectangle, radius 185 on the 824 pt body (22.4 %), as in the SVG.
func squircle(_ r: CGRect) -> CGPath {
    RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: r).cgPath
}

/// The blade of the SVG (`M512 512 C452 446 446 330 532 236 C628 300 640 430 556 504 C541 517 524 522 512 512 Z`),
/// in SVG coordinates (y down). The caller flips the context.
func blade() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 512, y: 512))
    p.addCurve(to: CGPoint(x: 532, y: 236), control1: CGPoint(x: 452, y: 446), control2: CGPoint(x: 446, y: 330))
    p.addCurve(to: CGPoint(x: 556, y: 504), control1: CGPoint(x: 628, y: 300), control2: CGPoint(x: 640, y: 430))
    p.addCurve(to: CGPoint(x: 512, y: 512), control1: CGPoint(x: 541, y: 517), control2: CGPoint(x: 524, y: 522))
    p.closeSubpath()
    return p
}

func render(pixels: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    // SVG coordinates: origin top-left, y down.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    // Drop shadow (macOS icon grid: soft, slightly below). Skipped at 16 px where it only muddies the edge.
    if pixels > 32 {
        ctx.saveGState()
        // Shadow offset and blur are in device space (not affected by the CTM): scale them by hand.
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: rgb(0x000000, 0.32))
        ctx.addPath(shape)
        ctx.setFillColor(rgb(0x0E1A2B))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Layer 1: night sky gradient + ember glow.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x1B2F4F), rgb(0x0E1A2B)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFF8A3D, 0.30), rgb(0xFF8A3D, 0)] as CFArray, locations: [0, 1])!
    let gc = CGPoint(x: 100 + 0.5 * 824, y: 100 + 0.56 * 824)
    ctx.drawRadialGradient(glow, startCenter: gc, startRadius: 0, endCenter: gc, endRadius: 0.42 * 824 * 1.2, options: [])
    // Faint top highlight (reads as depth on light and dark Docks).
    let hi = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 380), options: [])
    ctx.restoreGState()

    // Hairline edge so the dark body separates from a dark Dock.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // Layer 2: three blades, 120° apart, group rotated −8°; gradient hub (cool) → tip (hot) in blade space.
    // Small renditions get slightly fuller blades so the rotor stays legible.
    let bladeScale: CGFloat = pixels <= 32 ? 1.08 : 1
    let stops: [CGColor] = [rgb(0x4FD6E0), rgb(0xFFD54A), rgb(0xFF9A3D), rgb(0xFF4FA3)]
    let bladeGradient = CGGradient(colorsSpace: cs, colors: stops as CFArray, locations: [0, 0.45, 0.75, 1])!
    for k in 0..<3 {
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 512)
        ctx.rotate(by: CGFloat((-8 + 120 * Double(k)) * .pi / 180))
        ctx.scaleBy(x: bladeScale, y: bladeScale)
        ctx.translateBy(x: -512, y: -512)
        ctx.addPath(blade())
        ctx.clip()
        ctx.drawLinearGradient(bladeGradient, start: CGPoint(x: 512, y: 500), end: CGPoint(x: 540, y: 236),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // Layer 3: hub.
    let hubR: CGFloat = pixels <= 32 ? 54 : 46
    ctx.setFillColor(rgb(0xF4F7FB))
    ctx.fillEllipse(in: CGRect(x: 512 - hubR, y: 512 - hubR, width: 2 * hubR, height: 2 * hubR))
    ctx.setFillColor(rgb(0x0E1A2B, 0.85))
    ctx.fillEllipse(in: CGRect(x: 512 - 18, y: 512 - 18, width: 36, height: 36))
    return ctx.makeImage()!
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for s in sizes {
    let rep = NSBitmapImageRep(cgImage: render(pixels: s.px))
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try png.write(to: out.appendingPathComponent("\(s.name).png"))
    print("\(s.name).png \(s.px)px")
}
