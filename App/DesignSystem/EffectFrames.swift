//  EffectFrames.swift — the aurora, the heat glow and the chip thermal map, drawn on the CPU (MIT). OWNER: Unit 7.
//  Ported from the former Metal shaders (same noise, distances, falloffs and colour maths, checked pixel by pixel). A
//  SwiftUI Metal effect on screen, even a paused one, made RenderBox hold 70–260 MB of GPU surfaces; a frame here is a
//  small bitmap. Terms that change slowly across the picture (noise, the weighted temperature field) are computed every
//  2 points and interpolated, edges and iso-lines per pixel, so a frame costs a millisecond or two. Frames have unit
//  alpha: the shaders' final `* color.a` is the views' opacity (EffectLayer.LayerView.fill).
import Accelerate
import CoreGraphics
import Foundation
import simd

enum EffectFrames {
    /// Premultiplied sRGB components.
    typealias RGBA = SIMD4<Float>

    // MARK: Aurora

    /// The aurora at `time` on a `width × height` grid. The field is defined in coordinates normalized per axis, so the
    /// grid stretched to the view is the same picture: at 120 × 40 within 3/255 of the shader, at a quarter of the cost
    /// of 240 × 80.
    static func aurora(_ c0: RGBA, _ c1: RGBA, _ c2: RGBA, energy: Float, time: Float = 0,
                       width: Int = 120, height: Int = 40) -> CGImage? {
        let t = time * (0.04 + 0.12 * energy)
        return render(width: width, height: height) { x, y in
            let u = (Float(x) + 0.5) / Float(width), v = (Float(y) + 0.5) / Float(height)
            let n1 = fbm(u * 1.8 + t, v * 1.1 - t * 0.6)
            let n2 = fbm(u * 1.2 - t * 0.7 + 5, v * 2.2 - t * 0.3 + 5)
            let a = simd_mix(c0, c1, RGBA(repeating: smoothstep(0.3, 0.7, n1)))
            let b = simd_mix(a, c2, RGBA(repeating: smoothstep(0.45, 0.85, n2) * (0.5 + 0.4 * energy)))
            return b * (1 - smoothstep(0.35, 1, v))
        }
    }

    // MARK: Heat glow

    /// The heat glow at `time` as a white mask (its alpha is the glow) for a view of `width × height` points (card plus
    /// `spread` on every side), `scale` pixels per point. The view fills it with the tint.
    static func heatGlowMask(intensity: Float, cornerRadius: Float, spread: Float, width w: Float, height h: Float,
                             scale: Float, time: Float = 0) -> CGImage? {
        guard w >= 1, h >= 1, spread > 0 else { return nil }
        let cx = w * 0.5, cy = h * 0.5
        let hx = max(cx - spread, 1), hy = max(cy - spread, 1)
        let span = max(w, h)
        let reach = spread * (0.35 + 0.65 * intensity)
        let rise = time * (0.25 + 0.65 * intensity)                     // turbulence rises faster when hotter
        let breathe = 0.88 + 0.12 * sin(time * (1.2 + 1.8 * intensity))
        // Inside the card the glow is flat and reads no noise; a pixel outside reads grid nodes at most 2.83 points away.
        let noise = Grid(width: w, height: h) { px, py in
            sdRoundRect(px - cx, py - cy, hx, hy, cornerRadius) < -3 ? 0 : fbm(px / span * 5, py / span * 5 + rise)
        }
        let inside = min(max(0.18 * breathe * intensity, 0), 1)                 // faint inside the card
        return renderMask(width: max(Int((w * scale).rounded()), 1), height: max(Int((h * scale).rounded()), 1)) { x, y in
            let px = (Float(x) + 0.5) / scale, py = (Float(y) + 0.5) / scale
            let sd = sdRoundRect(px - cx, py - cy, hx, hy, cornerRadius)
            guard sd >= 0 else { return inside }
            let above = min(max((cy - py) / hy, 0), 1) * 0.35               // reaches further above the card
            var glow = exp(-sd / max(reach * (0.7 + 0.6 * noise[px, py] + above), 1) * 2.4) * breathe
            glow *= 1 - smoothstep(spread * 0.55, spread, sd)                // exactly 0 at the view's edge
            return min(max(glow * intensity, 0), 1)
        }
    }

    // MARK: Chip thermal map

    /// The thermal field for a view of `width × height` points at `scale` pixels per point: inverse-distance weighting
    /// of `sensors` (x, y in the unit square of the die, t on the scale's 0…1) with hotspot emphasis, coloured through
    /// `ramp` (uniform stops), with iso-lines every 10 % of the scale. The view clips it to its rounded rectangle.
    static func thermalField(sensors: [SIMD3<Float>], ramp: [SIMD3<Float>], power: Float, contours: Bool,
                             width w: Float, height h: Float, scale: Float) -> CGImage? {
        guard !sensors.isEmpty, ramp.count > 1, w >= 1, h >= 1 else { return nil }    // under a point: nothing to draw
        // The weighted field on the 2-point grid; pow and exp, the costly part, vectorized.
        let field = Grid(width: w, height: h, values: { columns, rows, step in
            let count = columns * rows
            var u = [Float](repeating: 0, count: count), v = u
            for j in 0..<rows {
                for i in 0..<columns { u[j * columns + i] = Float(i) * step / w; v[j * columns + i] = Float(j) * step / h }
            }
            var wsum = [Float](repeating: 0, count: count), tsum = wsum, tmax = wsum
            var base = wsum, hotArgument = wsum, weight = wsum, hot = wsum
            let exponent = [Float](repeating: -power / 2, count: count)
            for s in sensors {
                for k in 0..<count {
                    let dx = u[k] - s.x, dy = v[k] - s.y, d2 = dx * dx + dy * dy
                    base[k] = d2 + 0.0004
                    hotArgument[k] = -90 * d2
                }
                vForce.pow(bases: base, exponents: exponent, result: &weight)
                vForce.exp(hotArgument, result: &hot)
                for k in 0..<count {
                    wsum[k] += weight[k]
                    tsum[k] += weight[k] * s.z
                    tmax[k] = max(tmax[k], s.z * hot[k])                     // local hotspot emphasis
                }
            }
            return (0..<count).map { max(tsum[$0] / wsum[$0], tmax[$0] * 0.92) }
        })
        // A very faint grain on the colour lookup only (never on the iso-line test, which keeps the lines smooth).
        let grain = Grid(width: w, height: h) { px, py in (noise(px / w * 48, py / h * 48) - 0.5) * 0.008 }
        let last = Float(ramp.count - 1)
        return render(width: max(Int((w * scale).rounded()), 1), height: max(Int((h * scale).rounded()), 1)) { x, y in
            let px = (Float(x) + 0.5) / scale, py = (Float(y) + 0.5) / scale
            let t = field[px, py]
            let x = t + grain[px, py]
            let r = (x > 0 ? min(x, 1) : 0) * last                          // also 0 for NaN, which Int() would trap on
            let i = min(Int(r), ramp.count - 2)
            var c = simd_mix(ramp[i], ramp[i + 1], SIMD3(repeating: r - Float(i)))
            if contours {
                let d = abs(fract(t * 10 + 0.5) - 0.5)                      // 0 exactly on an iso-line
                c = simd_mix(c, c * 0.7, SIMD3(repeating: (1 - smoothstep(0.012, 0.035, d)) * 0.45))
            }
            return RGBA(c, 1)
        }
    }

    // MARK: Helpers (the shaders' value noise, 4-octave fBm and rounded-rectangle distance)

    /// A smooth function sampled every 2 points over a `width × height` view, read back with bilinear filtering.
    private struct Grid {
        static let step: Float = 2
        let columns: Int, rows: Int
        let values: [Float]

        init(width: Float, height: Float, values: (_ columns: Int, _ rows: Int, _ step: Float) -> [Float]) {
            columns = max(Int((width / Self.step).rounded(.up)) + 1, 2)
            rows = max(Int((height / Self.step).rounded(.up)) + 1, 2)
            self.values = values(columns, rows, Self.step)
        }

        init(width: Float, height: Float, _ f: (_ x: Float, _ y: Float) -> Float) {
            self.init(width: width, height: height) { columns, rows, step in
                (0..<(columns * rows)).map { f(Float($0 % columns) * step, Float($0 / columns) * step) }
            }
        }

        /// The value at (x, y) points.
        subscript(x: Float, y: Float) -> Float {
            let gx = min(max(x / Self.step, 0), Float(columns - 1)), gy = min(max(y / Self.step, 0), Float(rows - 1))
            let i = min(Int(gx), columns - 2), j = min(Int(gy), rows - 2)
            let fx = gx - Float(i), fy = gy - Float(j)
            let top = values[j * columns + i] + (values[j * columns + i + 1] - values[j * columns + i]) * fx
            let bottom = values[(j + 1) * columns + i] + (values[(j + 1) * columns + i + 1] - values[(j + 1) * columns + i]) * fx
            return top + (bottom - top) * fy
        }
    }

    private static func fract(_ x: Float) -> Float { x - x.rounded(.down) }

    private static func hash21(_ x: Float, _ y: Float) -> Float {
        var px = fract(x * 123.34), py = fract(y * 456.21)
        let d = px * (px + 45.32) + py * (py + 45.32)
        px += d; py += d
        return fract(px * py)
    }

    private static func noise(_ x: Float, _ y: Float) -> Float {
        let ix = x.rounded(.down), iy = y.rounded(.down)
        let fx = x - ix, fy = y - iy
        let a = hash21(ix, iy), b = hash21(ix + 1, iy), c = hash21(ix, iy + 1), d = hash21(ix + 1, iy + 1)
        let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
        let top = a + (b - a) * ux, bottom = c + (d - c) * ux
        return top + (bottom - top) * uy
    }

    private static func fbm(_ x: Float, _ y: Float) -> Float {
        var v: Float = 0, a: Float = 0.5, px = x, py = y
        for _ in 0..<4 {
            v += a * noise(px, py)
            px = px * 2.03 + 17; py = py * 2.03 + 17
            a *= 0.5
        }
        return v
    }

    private static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Signed distance from (dx, dy), relative to the centre, to a rounded rectangle of half-size (hx, hy), radius r.
    private static func sdRoundRect(_ dx: Float, _ dy: Float, _ hx: Float, _ hy: Float, _ r: Float) -> Float {
        let qx = abs(dx) - (hx - r), qy = abs(dy) - (hy - r)
        return simd_length(SIMD2(max(qx, 0), max(qy, 0))) + min(max(qx, qy), 0) - r
    }

    /// Premultiplied 8-bit sRGB image in Core Animation's own byte order (BGRA); row 0 is the top, as in SwiftUI's
    /// coordinates.
    private static func render(width: Int, height: Int, _ pixel: (Int, Int) -> RGBA) -> CGImage? {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let c = simd_clamp(pixel(x, y), RGBA(repeating: 0), RGBA(repeating: 1)) * 255
                    let i = (y * width + x) * 4
                    bytes[i] = UInt8(c.z.rounded()); bytes[i + 1] = UInt8(c.y.rounded())
                    bytes[i + 2] = UInt8(c.x.rounded()); bytes[i + 3] = UInt8(c.w.rounded())
                }
            }
        }
        return image(data, width: width, height: height)
    }

    /// A white mask (premultiplied, so every channel holds the alpha), laid out like `render`'s images.
    private static func renderMask(width: Int, height: Int, _ alpha: (Int, Int) -> Float) -> CGImage? {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let pixels = buffer.bindMemory(to: UInt32.self)
            for y in 0..<height {
                for x in 0..<width {
                    let a = alpha(x, y)
                    pixels[y * width + x] = a > 0 ? UInt32((min(a, 1) * 255).rounded()) * 0x0101_0101 : 0   // NaN: 0
                }
            }
        }
        return image(data, width: width, height: height)
    }

    private static func image(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                              | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
