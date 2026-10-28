//  ThermikTokens.swift — design tokens for Thermik (MIT). OWNER: Unit 7. Public API frozen for Unit 8 (additions allowed).
//  SPEC §4.2 / DES §7.3–7.5: thermal ramp (vivid + deep ink, colour-blind variant), per-class scales, typography,
//  metrics, motion and locale-safe number formatting.
import SwiftUI
import AppKit
import ThermikCore
import os

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
    /// Same text as `title`, as a String (AppKit menus, VoiceOver sentences, tooltips).
    var localizedTitle: String {
        switch self {
        case .frost: String(localized: "Cold"); case .cool: String(localized: "Cool"); case .normal: String(localized: "Normal")
        case .warm: String(localized: "Warm"); case .hot: String(localized: "Hot"); case .veryHot: String(localized: "Very hot")
        case .critical: String(localized: "Critical")
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
    /// Ramp position of the level's own stop (badges, chips).
    var stopT: Double { ThermalScale.stopT[rawValue] }
}

/// Maps °C → normalised t ∈ 0…1 on the shared colour ramp, per sensor class.
struct ThermalScale: Sendable, Hashable {
    /// °C at the 7 ramp stops (t = 0, .2, .4, .6, .75, .88, 1.0)
    let temps: [Double]
    static let stopT: [Double] = [0, 0.20, 0.40, 0.60, 0.75, 0.88, 1.0]

    // Defaults live in Core (`ThermalClass.stops`); the user can retune each class in Settings › Appearance.
    static var soc: ThermalScale { .scale(for: .soc) }          // CPU/GPU/ANE/SoC die
    static var power: ThermalScale { .scale(for: .power) }      // VRM / PMU / charger IC
    static var storage: ThermalScale { .scale(for: .storage) }  // NAND / SSD controller
    static var battery: ThermalScale { .scale(for: .battery) }  // cells / gas gauge
    static var ambient: ThermalScale { .scale(for: .ambient) }  // airflow, palm rest, skin

    /// The scale in effect for a class: the user's stops when set, else the defaults.
    static func scale(for c: ThermalClass) -> ThermalScale { ThermalScale(temps: ThermalScaleOverrides.stops(c) ?? c.stops) }

    /// Stops a user may store: seven finite values, each at least 1° above the previous one, within -20…130 °C.
    static func isValid(_ temps: [Double]) -> Bool {
        guard temps.count == stopT.count, temps.allSatisfy({ $0.isFinite && (-20...130).contains($0) }) else { return false }
        return zip(temps, temps.dropFirst()).allSatisfy { $1 - $0 >= 1 }
    }

    func normalized(_ celsius: Double) -> Double {
        guard celsius.isFinite, let first = temps.first, let last = temps.last else { return 0 }
        if celsius <= first { return 0 }
        if celsius >= last { return 1 }
        for i in 0..<(temps.count - 1) where celsius < temps[i + 1] {
            let f = (celsius - temps[i]) / (temps[i + 1] - temps[i])
            return Self.stopT[i] + f * (Self.stopT[i + 1] - Self.stopT[i])
        }
        return 1
    }

    func level(_ celsius: Double) -> ThermalLevel { Self.level(normalized: normalized(celsius)) }

    /// Level thresholds on t (SPEC §4.2.1): frost < 0.10 ≤ cool < 0.30 ≤ normal < 0.55 ≤ warm < 0.70 ≤ hot < 0.84
    /// ≤ very hot < 0.97 ≤ critical.
    static func level(normalized t: Double) -> ThermalLevel {
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
    init(_ c: ThermalClass) { self = .scale(for: c) }

    /// Colour scale of an aggregate (SPEC §4.2.2): die/SoC values use `soc`, the others their own class.
    static func of(_ kind: AggregateKind) -> ThermalScale {
        switch kind {
        case .ssd: return .storage
        case .battery: return .battery
        default: return .soc
        }
    }
}

/// User-tuned colour-scale stops per class (Settings › Appearance). Scales are read from any thread (labels, charts,
/// the menu bar renderer), so the table sits behind a lock; SettingsStore writes it on the main actor.
enum ThermalScaleOverrides {
    private static let table = OSAllocatedUnfairLock<[ThermalClass: [Double]]>(initialState: [:])

    static func stops(_ c: ThermalClass) -> [Double]? { table.withLock { $0[c] } }

    /// Replaces the table from the persisted form (`ThermalClass.rawValue` → stops); invalid entries are ignored.
    static func apply(_ stored: [String: [Double]]) {
        var t: [ThermalClass: [Double]] = [:]
        for (key, temps) in stored {
            guard let c = ThermalClass(rawValue: key), ThermalScale.isValid(temps) else { continue }
            t[c] = temps
        }
        let valid = t
        table.withLock { $0 = valid }
    }
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
    /// Colour-blind-friendly fills (Settings › Appearance; DES §7.3.1, Machado 2009 simulation: min ΔE 8.2 / 7.9 / 6.1 / 7.2).
    static let colorBlindVivid: [RGB] = [0x5AA9F0, 0x8CC8F2, 0xC3D3DC, 0xF5C46A, 0xF59A45, 0xE8603A, 0xD6336C].map(RGB.init)
    /// Dark-mode text in colour-blind mode: the two hottest fills are too dark on #2A2A2C, so text uses #F07A55 / #FF6B9A.
    static let colorBlindInkDark: [RGB] = [0x5AA9F0, 0x8CC8F2, 0xC3D3DC, 0xF5C46A, 0xF59A45, 0xF07A55, 0xFF6B9A].map(RGB.init)

    static func sample(_ ramp: [RGB], _ t: Double) -> RGB {
        guard !ramp.isEmpty else { return RGB(r: 0.5, g: 0.5, b: 0.5) }
        let x = t.isFinite ? min(max(t, 0), 1) : 0
        let T = ThermalScale.stopT
        for i in 0..<(min(T.count, ramp.count) - 1) where x <= T[i + 1] {
            return ramp[i].mix(ramp[i + 1], (x - T[i]) / (T[i + 1] - T[i]))
        }
        return ramp[ramp.count - 1]
    }

    /// Vivid colour for t (appearance-independent).
    static func vivid(_ t: Double) -> Color { sample(vivid, t).color }

    /// Contrast-safe text colour for t that adapts to light/dark automatically.
    static func ink(_ t: Double) -> Color { ThermikRamp.standard.ink(t) }

    // Brand
    static let brandSky    = RGB(0x3D7BFF).color   // "updraft blue"
    static let brandEmber  = RGB(0xFF8A3D).color   // "ember"

    /// True for dark (and high-contrast dark) appearances.
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark,
                                    .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                    .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark])
            .map { [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark].contains($0) }
            ?? false
    }
}

/// One complete colour ramp (standard or colour-blind-friendly). Views read the active one from
/// `@Environment(\.thermikRamp)`; hosted roots set it from `settings.colorBlindScale` (`.thermikDesignEnvironment(_:)`).
struct ThermikRamp: Sendable, Hashable {
    let vivid: [RGB]
    let inkLight: [RGB]
    let inkDark: [RGB]

    static let standard = ThermikRamp(vivid: ThermikPalette.vivid, inkLight: ThermikPalette.inkLight, inkDark: ThermikPalette.inkDark)
    /// Fills from the CVD ramp; light-mode text keeps the deep inks (all ≥ 4.5:1), dark-mode text the adjusted CVD inks.
    static let colorBlind = ThermikRamp(vivid: ThermikPalette.colorBlindVivid, inkLight: ThermikPalette.inkLight,
                                        inkDark: ThermikPalette.colorBlindInkDark)

    static func forSettings(colorBlind: Bool) -> ThermikRamp { colorBlind ? .colorBlind : .standard }

    func vivid(_ t: Double) -> Color { ThermikPalette.sample(vivid, t).color }

    /// Text/stroke colour for a known appearance (AppKit drawing, menu bar label).
    func nsInk(_ t: Double, dark: Bool) -> NSColor { ThermikPalette.sample(dark ? inkDark : inkLight, t).nsColor }

    /// Appearance-adaptive text colour (≥ 4.5:1 on cards in both appearances; Increase Contrast keeps these inks).
    func ink(_ t: Double) -> Color {
        let light = nsInk(t, dark: false), dark = nsInk(t, dark: true)
        return Color(nsColor: NSColor(name: nil) { ap in ThermikPalette.isDark(ap) ? dark : light })
    }

    /// The vivid ramp resampled into 11 uniformly spaced stops, as the chip thermal map reads it.
    var fieldStops: [RGB] { (0...10).map { ThermikPalette.sample(vivid, Double($0) / 10) } }
}

extension EnvironmentValues {
    /// Active thermal ramp (standard or colour-blind-friendly).
    @Entry var thermikRamp: ThermikRamp = .standard
}

// MARK: - Typography

enum ThermikFont {
    /// Hero number in popover header / overview (SF Pro Rounded, tabular).
    static let hero      = Font.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit()
    static let display   = Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
    static let value     = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
    static let valueSmall = Font.system(size: 13, weight: .medium, design: .rounded).monospacedDigit()
    static let unit      = Font.system(size: 11, weight: .medium, design: .rounded)
    static let body      = Font.system(size: 12, weight: .regular)                   // sensor names, row labels
    static let caption   = Font.system(size: 11, weight: .regular)
    static let sectionTitle = Font.system(size: 11, weight: .semibold).smallCaps()
    static let mono      = Font.system(size: 11, weight: .regular, design: .monospaced)  // SMC keys, logs

    /// AppKit: SF Pro Rounded with tabular digits (menu bar label). Falls back to SF Pro if Rounded is unavailable.
    static func roundedMonoDigits(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}

// MARK: - Metrics

enum ThermikMetrics {
    static let popoverWidth: CGFloat = 360
    static let popoverMaxHeight: CGFloat = 620
    static let popoverRadius: CGFloat = 18
    static let cardRadius: CGFloat = 14
    static let innerRadius: CGFloat = 10
    static let gutter: CGFloat = 12
    static let rowHeight: CGFloat = 26
    static let compactRowHeight: CGFloat = 22        // popover density "compact" (P1)
    static let groupHeaderHeight: CGFloat = 30
    static let sparklineHeight: CGFloat = 18
    static let sparklineWidth: CGFloat = 54
    /// Menu bar labels are designed for this content box; never assume the menu bar height (DES §2.1).
    static let menuBarContentHeight: CGFloat = 22
}

// MARK: - Motion (SPEC §4.2.5; data ticks never animate: values, bars and chart marks change in one step)

enum ThermikMotion {
    static let disclosure = Animation.snappy(duration: 0.28)
    static let modeMorph = Animation.bouncy(duration: 0.35)

    /// `animation` unless Reduce Motion is on (then changes are instant).
    static func unlessReduced(_ animation: Animation, _ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : animation }
}

// MARK: - Number formatting (locale-safe: never let LocalizedStringKey group "1 840")

enum ThermikFormat {
    static func temp(_ c: Double, unit: UnitTemperature = .celsius, decimals: Int = 0) -> String {
        number(convert(c, to: unit), decimals: decimals) + "°"
    }
    static func rpm(_ r: Double) -> String { number(r, decimals: 0) }
    /// `p` is a fraction (0.45 → "45 %" in Russian, "45%" in English).
    static func percent(_ p: Double) -> String { p.formatted(.percent.precision(.fractionLength(0))) }
    /// "38.2 W" / «38,2 Вт» (non-breaking space before the unit, SPEC §4.12).
    static func watts(_ w: Double) -> String { number(w, decimals: 1) + "\u{00A0}" + wattUnit }

    // Additions (Unit 7)

    /// Temperature in the display unit, rounded the way the UI shows it (menu bar change detection, VoiceOver).
    static func degrees(_ c: Double, unit: UnitTemperature = .celsius) -> Int {
        let v = convert(c, to: unit)
        return v.isFinite ? Int(v.rounded()) : 0
    }
    static func convert(_ c: Double, to unit: UnitTemperature) -> Double { unit == .fahrenheit ? c * 9 / 5 + 32 : c }
    /// `p` is 0…100 (fan percent semantics).
    static func percentValue(_ p: Double) -> String { percent(p / 100) }
    /// "2310 rpm" / «2310 об/мин».
    static func rpmWithUnit(_ r: Double) -> String { rpm(r) + "\u{00A0}" + rpmUnit }
    /// "38 W" (whole watts, menu bar).
    static func wattsShort(_ w: Double) -> String { number(w, decimals: 0) + wattUnit }
    /// Copy-to-pasteboard form: "62.4 °C" / «62,4 °C».
    static func tempWithUnit(_ c: Double, unit: UnitTemperature = .celsius, decimals: Int = 1) -> String {
        number(convert(c, to: unit), decimals: decimals) + "\u{00A0}" + (unit == .fahrenheit ? "°F" : "°C")
    }

    static var rpmUnit: String { String(localized: "rpm") }
    static var wattUnit: String { String(localized: "unit.watts", defaultValue: "W", comment: "Watt unit symbol") }

    private static func number(_ v: Double, decimals: Int) -> String {
        guard v.isFinite else { return "—" }
        return v.formatted(.number.precision(.fractionLength(decimals)).grouping(.never))
    }
}
