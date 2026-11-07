// render-icon.swift — Thermik (MIT). Renders the app icon PNGs from the vector concept of
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
    let (ctx, scale) = makeContext(pixels: pixels, colorSpace: cs)
    let shape = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
    drawShadow(ctx, shape: shape, pixels: pixels, scale: scale)
    drawBackground(ctx, shape: shape, colorSpace: cs)
    drawEdge(ctx, shape: shape)
    drawBlades(ctx, pixels: pixels, colorSpace: cs)
    drawHub(ctx, pixels: pixels)
    return ctx.makeImage()!
}

private func makeContext(pixels: Int, colorSpace: CGColorSpace) -> (CGContext, CGFloat) {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    // SVG coordinates: origin top-left, y down.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return (ctx, scale)
}

// Drop shadow (macOS icon grid: soft, slightly below). Skipped at 16 px where it only muddies the edge.
private func drawShadow(_ ctx: CGContext, shape: CGPath, pixels: Int, scale: CGFloat) {
    guard pixels > 32 else { return }
    ctx.saveGState()
    // Shadow offset and blur are in device space (not affected by the CTM): scale them by hand.
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: rgb(0x000000, 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x0E1A2B))
    ctx.fillPath()
    ctx.restoreGState()
}

// Layer 1: night sky gradient + ember glow.
private func drawBackground(_ ctx: CGContext, shape: CGPath, colorSpace: CGColorSpace) {
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    drawSky(ctx, colorSpace: colorSpace)
    drawGlow(ctx, colorSpace: colorSpace)
    drawHighlight(ctx, colorSpace: colorSpace)
    ctx.restoreGState()
}

private func drawSky(_ ctx: CGContext, colorSpace: CGColorSpace) {
    let bg = CGGradient(colorsSpace: colorSpace, colors: [rgb(0x1B2F4F), rgb(0x0E1A2B)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
}

private func drawGlow(_ ctx: CGContext, colorSpace: CGColorSpace) {
    let glow = CGGradient(colorsSpace: colorSpace, colors: [rgb(0xFF8A3D, 0.30), rgb(0xFF8A3D, 0)] as CFArray, locations: [0, 1])!
    let gc = CGPoint(x: 100 + 0.5 * 824, y: 100 + 0.56 * 824)
    ctx.drawRadialGradient(glow, startCenter: gc, startRadius: 0, endCenter: gc, endRadius: 0.42 * 824 * 1.2, options: [])
}

// Faint top highlight (reads as depth on light and dark Docks).
private func drawHighlight(_ ctx: CGContext, colorSpace: CGColorSpace) {
    let hi = CGGradient(colorsSpace: colorSpace, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 380), options: [])
}

// Hairline edge so the dark body separates from a dark Dock.
private func drawEdge(_ ctx: CGContext, shape: CGPath) {
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

// Layer 2: three blades, 120° apart, group rotated −8°; gradient hub (cool) → tip (hot) in blade space.
// Small renditions get slightly fuller blades so the rotor stays legible.
private func drawBlades(_ ctx: CGContext, pixels: Int, colorSpace: CGColorSpace) {
    let bladeScale: CGFloat = pixels <= 32 ? 1.08 : 1
    let stops: [CGColor] = [rgb(0x4FD6E0), rgb(0xFFD54A), rgb(0xFF9A3D), rgb(0xFF4FA3)]
    let gradient = CGGradient(colorsSpace: colorSpace, colors: stops as CFArray, locations: [0, 0.45, 0.75, 1])!
    for k in 0..<3 {
        drawBlade(ctx, index: k, scale: bladeScale, gradient: gradient)
    }
}

private func drawBlade(_ ctx: CGContext, index: Int, scale: CGFloat, gradient: CGGradient) {
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: CGFloat((-8 + 120 * Double(index)) * .pi / 180))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -512, y: -512)
    ctx.addPath(blade())
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 500), end: CGPoint(x: 540, y: 236),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// Layer 3: hub.
private func drawHub(_ ctx: CGContext, pixels: Int) {
    let hubR: CGFloat = pixels <= 32 ? 54 : 46
    ctx.setFillColor(rgb(0xF4F7FB))
    ctx.fillEllipse(in: CGRect(x: 512 - hubR, y: 512 - hubR, width: 2 * hubR, height: 2 * hubR))
    ctx.setFillColor(rgb(0x0E1A2B, 0.85))
    ctx.fillEllipse(in: CGRect(x: 512 - 18, y: 512 - 18, width: 36, height: 36))
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
