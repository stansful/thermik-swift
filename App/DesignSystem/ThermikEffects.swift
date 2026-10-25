//  ThermikEffects.swift — SwiftUI wrappers around ThermikShaders.metal (MIT).
import SwiftUI

enum ThermikShaders {
    /// In the app target this is simply `.default` (Xcode compiles every .metal file into default.metallib).
    /// Tests / CLI harnesses can point it at an explicit metallib.
    nonisolated(unsafe) static var library: ShaderLibrary = .default
}

/// Global switch for decorative animation: honours Reduce Motion, Low Power Mode and the in-app setting.
struct EffectsPolicy {
    var reduceMotion: Bool
    var lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    var userEnabled: Bool = true
    var animate: Bool { userEnabled && !reduceMotion && !lowPower }
}

// MARK: - 1. Heat glow behind the hottest card

/// Place *behind* a card: `.background { HeatGlow(intensity:tint:) }`.
/// `intensity` 0…1 — map from ThermalScale.normalized(temp) with a dead zone (no glow below "warm").
struct HeatGlow: View {
    var intensity: Double
    var tint: Color
    var cornerRadius: CGFloat = ThermikMetrics.cardRadius
    var spread: CGFloat = 22
    var fps: Double = 15          // measured: 30 fps ≈ 4–9 % CPU, 15 fps ≈ half; the glow is slow so 15 is enough
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var epoch = Date()

    static func intensity(forNormalized t: Double) -> Double {
        // 0 below t = 0.55 (warm), eases in to 1 at critical.
        let x = max(0, (t - 0.55) / 0.45)
        return x * x * (3 - 2 * x)
    }

    var body: some View {
        let active = intensity > 0.02
        let animate = EffectsPolicy(reduceMotion: reduceMotion).animate
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: !(active && animate))) { ctx in
            let t = Float(ctx.date.timeIntervalSince(epoch).truncatingRemainder(dividingBy: 3600))
            Rectangle()
                .colorEffect(ThermikShaders.library.heatGlow(
                    .boundingRect, .float(t), .float(Float(intensity)), .color(tint),
                    .float(Float(cornerRadius)), .float(Float(spread))), isEnabled: active)
                .opacity(active ? 1 : 0)
        }
        .padding(-spread)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.6), value: intensity)
    }
}

// MARK: - 2. Heat shimmer (only at "critical")

struct HeatShimmer: ViewModifier {
    var amplitude: CGFloat  // 0 disables
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var epoch = Date()
    func body(content: Content) -> some View {
        let on = amplitude > 0.05 && EffectsPolicy(reduceMotion: reduceMotion).animate
        let amp = amplitude, lib = ThermikShaders.library
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !on)) { ctx in
            let t = Float(ctx.date.timeIntervalSince(epoch).truncatingRemainder(dividingBy: 3600))
            // .visualEffect gives us the view's own size without a GeometryReader (macOS 14+).
            content.visualEffect { effect, proxy in
                effect.distortionEffect(
                    lib.heatShimmer(.float2(proxy.size), .float(t), .float(Float(amp))),
                    maxSampleOffset: CGSize(width: amp, height: amp),
                    isEnabled: on)
            }
        }
    }
}
extension View {
    func heatShimmer(_ amplitude: CGFloat) -> some View { modifier(HeatShimmer(amplitude: amplitude)) }
}

// MARK: - 3. Chip thermal map

struct DieSensor: Identifiable, Sendable, Hashable {
    let id: String          // SMC key or HID name
    let label: String       // "P-Core 3", "GPU 2", …
    let position: CGPoint   // unit square of the die (0…1), from a per-chip layout table
    var celsius: Double
    var scale: ThermalScale = .soc
}

/// Smooth heat field interpolated (inverse-distance weighting) from sparse sensors.
/// Static by default (redraws only when values change, i.e. at sensor cadence ~1 Hz).
struct ThermalFieldView: View {
    var sensors: [DieSensor]
    var cornerRadius: CGFloat = 12
    var power: Double = 2.6
    var contours: Bool = true
    var showsMarkers: Bool = true
    @Binding var hovered: DieSensor.ID?

    var body: some View {
        let packed: [Float] = sensors.flatMap { s in
            [Float(s.position.x), Float(s.position.y), Float(s.scale.normalized(s.celsius))]
        }
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .colorEffect(ThermikShaders.library.thermalField(
                        .boundingRect, .floatArray(packed), .colorArray(ThermikPalette.shaderRamp),
                        .float(Float(power)), .float(0), .float(contours ? 1 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1))
                if showsMarkers {
                    ForEach(sensors) { s in
                        Circle()
                            .fill(.white.opacity(hovered == s.id ? 1 : 0.75))
                            .frame(width: hovered == s.id ? 9 : 5, height: hovered == s.id ? 9 : 5)
                            .shadow(color: .black.opacity(0.35), radius: 1.5)
                            .position(x: s.position.x * geo.size.width, y: s.position.y * geo.size.height)
                            .onHover { inside in hovered = inside ? s.id : (hovered == s.id ? nil : hovered) }
                            .help("\(s.label): \(ThermikFormat.temp(s.celsius))")
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chip thermal map")
        .accessibilityValue(sensors.sorted { $0.celsius > $1.celsius }.prefix(3)
            .map { "\($0.label) \(ThermikFormat.temp($0.celsius))" }.joined(separator: ", "))
    }
}

// MARK: - 4. Aurora header

struct AuroraBackground: View {
    var normalized: Double      // hottest sensor, 0…1
    var energy: Double          // thermal pressure 0…1 (nominal 0, fair .33, serious .66, critical 1)
    var fps: Double = 12        // measured: 20 fps ≈ 6–7 % CPU; motion is very slow, 10–12 fps is indistinguishable
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var epoch = Date()

    var body: some View {
        let base = ThermikPalette.sample(ThermikPalette.vivid, normalized)
        // Analogous hues only (±0.1 on the ramp) — mixing e.g. green + orange turns muddy (seen in renders).
        let cool = ThermikPalette.sample(ThermikPalette.vivid, max(0, normalized - 0.10))
        let hot  = ThermikPalette.sample(ThermikPalette.vivid, min(1, normalized + 0.10))
        let alpha = scheme == .dark ? 0.42 : 0.34
        let animate = EffectsPolicy(reduceMotion: reduceMotion).animate
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: !animate)) { ctx in
            let t = Float(ctx.date.timeIntervalSince(epoch).truncatingRemainder(dividingBy: 3600))
            Rectangle().colorEffect(ThermikShaders.library.aurora(
                .boundingRect, .float(t),
                .color(cool.color.opacity(alpha)), .color(base.color.opacity(alpha)), .color(hot.color.opacity(alpha)),
                .float(Float(energy))))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 5. Spark glow for sparklines (dark mode only)
extension View {
    @ViewBuilder func sparkGlow(_ radius: CGFloat = 3, enabled: Bool = true) -> some View {
        self.layerEffect(ThermikShaders.library.sparkGlow(.float(Float(radius))),
                         maxSampleOffset: CGSize(width: radius, height: radius), isEnabled: enabled)
    }
}
