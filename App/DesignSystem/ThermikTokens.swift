//  ThermikTokens.swift — design tokens for Thermik (MIT).
import SwiftUI
import AppKit
import ThermikCore

// MARK: - Thermal levels & per-sensor-class scales

/// Seven semantic levels. Raw value = index into the 7-stop ramp.
enum ThermalLevel: Int, CaseIterable, Sendable, Comparable {
    case frost, cool, normal, warm, hot, veryHot, critical
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .frost: "Cold"; case .cool: "Cool"; case .normal: "Normal"; case .warm: "Warm"
        case .hot: "Hot"; case .veryHot: "Very hot"; case .critical: "Critical"
        }
    }
    /// Secondary, non-colour cue (WCAG 1.4.1): every level also has a glyph.
    var symbol: String {
        switch self {
        case .frost: "snowflake"
        case .cool, .normal: "checkmark.circle"
        case .warm: "thermometer.medium"
        case .hot: "thermometer.high"
        case .veryHot: "exclamationmark.triangle"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}

/// Maps °C → normalised t ∈ 0…1 on the shared colour ramp, per sensor class.
struct ThermalScale: Sendable, Hashable {
    /// °C at the 7 ramp stops (t = 0, .2, .4, .6, .75, .88, 1.0)
    let temps: [Double]
    static let stopT: [Double] = [0, 0.20, 0.40, 0.60, 0.75, 0.88, 1.0]

    static let soc      = ThermalScale(temps: [30, 45, 60, 75, 85, 95, 105])  // CPU/GPU/ANE/SoC die
    static let power    = ThermalScale(temps: [30, 45, 60, 75, 85, 95, 105])  // VRM / PMU / charger IC
    static let storage  = ThermalScale(temps: [25, 35, 45, 55, 65, 72, 80])   // NAND / SSD controller
    static let battery  = ThermalScale(temps: [20, 28, 33, 38, 42, 46, 50])   // cells / gas gauge
    static let ambient  = ThermalScale(temps: [15, 22, 28, 34, 38, 42, 46])   // airflow, palm rest, skin

    func normalized(_ celsius: Double) -> Double {
        guard let first = temps.first, let last = temps.last else { return 0 }
        if celsius <= first { return 0 }
        if celsius >= last { return 1 }
        for i in 0..<(temps.count - 1) where celsius < temps[i + 1] {
            let f = (celsius - temps[i]) / (temps[i + 1] - temps[i])
            return Self.stopT[i] + f * (Self.stopT[i + 1] - Self.stopT[i])
        }
        return 1
    }

    func level(_ celsius: Double) -> ThermalLevel {
        let t = normalized(celsius)
        switch t {
        case ..<0.10: return .frost
        case ..<0.30: return .cool
        case ..<0.55: return .normal
        case ..<0.70: return .warm
        case ..<0.84: return .hot
        case ..<0.97: return .veryHot
        default:      return .critical
        }
    }
}

extension ThermalScale {
    /// Bridge from Core's per-sensor colour class (keeps the memberwise init available).
    init(_ c: ThermalClass) { self.init(temps: c.stops) }
}

// MARK: - Colour

struct RGB: Sendable, Hashable { let r, g, b: Double
    init(_ hex: UInt32) { r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255 }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    func mix(_ o: RGB, _ f: Double) -> RGB { RGB(r: r + (o.r - r) * f, g: g + (o.g - g) * f, b: b + (o.b - b) * f) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

enum ThermikPalette {
    /// Vivid ramp: fills, glows, heat-map, chart areas (both appearances).
    static let vivid: [RGB] = [0x7CC8FF, 0x4FD6E0, 0x7EE08A, 0xFFD54A, 0xFF9A3D, 0xFF5A4E, 0xFF4FA3].map(RGB.init)
    /// Ink ramp for text/strokes on LIGHT surfaces (≥ 4.5:1 on #F4F4F6).
    static let inkLight: [RGB] = [0x0A66C2, 0x007680, 0x237A2E, 0x8F6200, 0xAD4B00, 0xC8281F, 0xB8146F].map(RGB.init)
    /// Ink ramp for text/strokes on DARK surfaces (≥ 4.6:1 on #2A2A2C) — identical to vivid.
    static let inkDark: [RGB] = vivid

    static func sample(_ ramp: [RGB], _ t: Double) -> RGB {
        let x = min(max(t, 0), 1)
        let T = ThermalScale.stopT
        for i in 0..<(T.count - 1) where x <= T[i + 1] {
            return ramp[i].mix(ramp[i + 1], (x - T[i]) / (T[i + 1] - T[i]))
        }
        return ramp[ramp.count - 1]
    }

    /// Vivid colour for t (appearance-independent).
    static func vivid(_ t: Double) -> Color { sample(vivid, t).color }

    /// Contrast-safe text colour for t that adapts to light/dark automatically.
    static func ink(_ t: Double) -> Color {
        let light = sample(inkLight, t).nsColor, dark = sample(inkDark, t).nsColor
        return Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
        })
    }

    /// Shader ramp (pass with Shader.Argument.colorArray). Stops are *uniformly* spaced in the shader,
    /// so we resample the non-uniform design ramp into 11 uniform stops.
    static let shaderRamp: [Color] = (0...10).map { sample(vivid, Double($0) / 10).color }

    // Brand
    static let brandDeep   = RGB(0x0E1A2B).color   // "night sky"
    static let brandSky    = RGB(0x3D7BFF).color   // "updraft blue"
    static let brandEmber  = RGB(0xFF8A3D).color   // "ember"
}

// MARK: - Typography

enum ThermikFont {
    /// Hero number in popover header / overview (SF Pro Rounded, tabular).
    static let hero      = Font.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit()
    static let display   = Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
    static let value     = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
    static let valueSmall = Font.system(size: 13, weight: .medium, design: .rounded).monospacedDigit()
    static let unit      = Font.system(size: 11, weight: .medium, design: .rounded)
    static let caption   = Font.system(size: 11, weight: .regular)
    static let sectionTitle = Font.system(size: 11, weight: .semibold).smallCaps()
    static let mono      = Font.system(size: 11, weight: .regular, design: .monospaced)  // SMC keys, logs
}

// MARK: - Metrics

enum ThermikMetrics {
    static let popoverWidth: CGFloat = 360
    static let popoverMaxHeight: CGFloat = 620
    static let cardRadius: CGFloat = 14
    static let innerRadius: CGFloat = 10
    static let gutter: CGFloat = 12
    static let rowHeight: CGFloat = 26
    static let sparklineHeight: CGFloat = 18
}

// MARK: - Number formatting (locale-safe: never let LocalizedStringKey group "1 840")

enum ThermikFormat {
    static func temp(_ c: Double, unit: UnitTemperature = .celsius, decimals: Int = 0) -> String {
        let v = unit == .fahrenheit ? c * 9 / 5 + 32 : c
        return v.formatted(.number.precision(.fractionLength(decimals)).grouping(.never)) + "°"
    }
    static func rpm(_ r: Double) -> String { r.formatted(.number.precision(.fractionLength(0)).grouping(.never)) }
    static func percent(_ p: Double) -> String { p.formatted(.percent.precision(.fractionLength(0))) }
    static func watts(_ w: Double) -> String { w.formatted(.number.precision(.fractionLength(1)).grouping(.never)) + " W" }
}
