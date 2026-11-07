//  MenuBarLabel.swift — status-item label rendering (MIT).
//  MenuBarExtra's label only honours ONE Text and/or ONE Image (verified on macOS 27: a VStack collapses
//  to its first Text). Multi-line / multi-metric labels are therefore drawn into an NSImage with AppKit
//  (DES §2.1: 0.50 % CPU at 1 Hz vs 1.09 % for ImageRenderer), template unless colour is needed.
//  Rules (SPEC §4.4): 22-pt content box; fixed width per style and metric kinds (pad to 88° / 8888 rpm) so the
//  item never jitters; redraw only when the visible text changes (the cache key IS the visible content, plus the
//  backing scales it was rasterised for); LRU of 64.
import SwiftUI
import AppKit

// MenuBarStyle lives in App/Shared/SettingsModels.swift (persisted).

/// What a label slot can show (the kind decides the reserved width, so "—" at launch is as wide as "62°").
enum MenuBarReadingKind: Hashable, Sendable { case temperature, rpm, watts, none }

/// One label slot.
enum MenuBarReading: Hashable, Sendable {
    case temperature(Double, scale: ThermalScale)   // °C (converted to the display unit when drawn)
    case rpm(Double)                                // ≤ 50 rpm → "Off"
    case watts(Double)
    case unavailable(MenuBarReadingKind)            // "—"
    case none

    var kind: MenuBarReadingKind {
        switch self {
        case .temperature: .temperature
        case .rpm: .rpm
        case .watts: .watts
        case .unavailable(let k): k
        case .none: .none
        }
    }

    var celsius: Double? { if case .temperature(let c, _) = self { c } else { nil } }
}

/// ◆ while Thermik forces the fans; `!` in the critical colour during the safety override (SPEC §4.4).
enum MenuBarBadge: Hashable, Sendable { case none, override, safety }

struct MenuBarSnapshot: Equatable, Sendable {
    var celsius: Double
    var rpm: Double?
    var normalized: Double          // for colour / gauge fill
    var alert: Bool                 // ≥ very hot or a user alert is raised
    // Defaults keep the original memberwise init `MenuBarSnapshot(celsius:rpm:normalized:alert:)`.
    var primary: MenuBarReading? = nil       // nil → .temperature(celsius, .soc)
    var secondary: MenuBarReading? = nil     // nil → rpm.map(.rpm) ?? .none
    var fahrenheit = false
    var stale = false                        // last value + "·"
    var badge: MenuBarBadge = .none
    /// VoiceOver / tooltip text ("Thermik, CPU 62 degrees, fans 1840 rpm"); nil → "Thermik, 62 degrees".
    var accessibilityText: String? = nil
    /// Recent primary values, oldest first (°C or rpm), for the `sparkline` style only.
    var history: [Double] = []
    /// Composed styles (presets built from values, and «Свой вариант»): the layout and its resolved values in order.
    var composition: MenuBarCustomLabel? = nil
    var composed: [MenuBarComposedValue] = []

    var resolvedPrimary: MenuBarReading { primary ?? .temperature(celsius, scale: .soc) }
    var resolvedSecondary: MenuBarReading { secondary ?? (rpm.map { .rpm($0) } ?? .none) }
    var unit: UnitTemperature { fahrenheit ? .fahrenheit : .celsius }
}

/// One resolved value of a composed label (MenuBarController / the style gallery fill it from the stores).
struct MenuBarComposedValue: Equatable, Sendable {
    var reading: MenuBarReading
    var symbol: String?                  // SF Symbol in front of the value
    var graphic: MenuBarIcon = .none     // .ring / .level / .graph drawn from `fraction` / `history`
    var caption = ""
    var showUnit = false
    var fraction = 0.0                   // place on its scale 0…1 (temperature) or of the max speed (fans)
    var history: [Double] = []           // graph values, oldest first
}

/// How a label is coloured. `appearance` is the status bar button's effective appearance (only used for non-template
/// drawing: label colour and light/dark inks).
struct MenuBarRenderOptions: Hashable, Sendable {
    var colored = false                  // settings.menuBar.colored
    var alertColor = true                // colour while `snapshot.alert` (settings.menuBar.alertColor)
    var colorBlind = false               // settings.colorBlindScale
    var appearance: NSAppearance.Name = .aqua
}

/// Everything that is visible in one label. Hashable: it is the cache key and the "did the text change?" test.
struct MenuBarLabelContent: Hashable, Sendable {
    var style: MenuBarStyle
    var primaryText: String
    var primaryKind: MenuBarReadingKind
    var secondaryText: String
    var secondaryKind: MenuBarReadingKind
    var widthKey: String                 // localized templates (language can change only at relaunch)
    var fraction: Double                 // gauge fill, 0.02 steps
    var tint: Double?                    // ramp t of the primary value when coloured
    var alert: Bool
    var stale: Bool
    var badge: MenuBarBadge
    var template: Bool
    var dark: Bool
    var colorBlind: Bool
    var spark: [Double] = []             // sparkline points 0…1 (1/40 steps), empty for the other styles
    var composedLayout: ComposedLayout? = nil
    var composed: [ComposedValueContent] = []
}

/// The drawing-relevant part of a MenuBarCustomLabel (no item ids, so equal labels share one cached image).
struct ComposedLayout: Hashable, Sendable {
    var layout: MenuBarCustomLabel.Layout
    var size: MenuBarCustomLabel.TextSize
    var bold: Bool
    var separator: MenuBarCustomLabel.Separator
    var badge: Bool
    var tintIcons: Bool
}

struct ComposedValueContent: Hashable, Sendable {
    var text: String
    var kind: MenuBarReadingKind
    var showUnit: Bool
    var symbol: String?
    var graphic: MenuBarIcon
    var caption: String
    var tint: Double?                    // ramp t when coloured
    var fraction: Double                 // 0.02 steps
    var spark: [Double]
}

@MainActor
final class MenuBarLabelRenderer {
    /// Cache key: the visible content plus the backing scales the image was rasterised for (an image drawn while only
    /// a 1× display was attached must not be reused once a 2× one shows the menu bar).
    private struct CacheKey: Hashable {
        var content: MenuBarLabelContent
        var scales: [CGFloat]
    }
    private var cache: [CacheKey: NSImage] = [:]
    private var order: [CacheKey] = []
    private var widths: [String: CGFloat] = [:]
    /// Number of images actually drawn (cache misses) — debug statistics.
    private(set) var renderCount = 0

    /// Template unless `colored`; drawn for `scale` (and 2×).
    func image(for s: MenuBarSnapshot, style: MenuBarStyle, colored: Bool, scale: CGFloat) -> NSImage {
        let appearance = NSApp?.effectiveAppearance.name ?? .aqua
        return image(for: s, style: style, options: MenuBarRenderOptions(colored: colored, appearance: appearance),
                     scales: Array(Set([scale, 2])).sorted())
    }

    /// Image for the status item. `scales`: backing scale factors to rasterise (default: every attached screen).
    func image(for s: MenuBarSnapshot, style: MenuBarStyle, options: MenuBarRenderOptions,
               scales: [CGFloat] = MenuBarLabelRenderer.screenScales) -> NSImage {
        let c = content(for: s, style: style, options: options)
        let key = CacheKey(content: c, scales: scales.isEmpty ? [2] : Array(Set(scales)).sorted())
        if let hit = cache[key] { return hit }
        let img = draw(c, scales: key.scales)
        img.accessibilityDescription = s.accessibilityText
            ?? "Thermik, " + String(localized: "\(ThermikFormat.degrees(s.celsius, unit: s.unit)) degrees")
        cache[key] = img; order.append(key)
        if order.count > 64 { cache.removeValue(forKey: order.removeFirst()) }   // tiny LRU
        renderCount += 1
        return img
    }

    static var screenScales: [CGFloat] {
        let s = Set(NSScreen.screens.map(\.backingScaleFactor))
        return s.isEmpty ? [2] : s.sorted()
    }

    // MARK: Content (strings + colours)

    func content(for s: MenuBarSnapshot, style: MenuBarStyle, options: MenuBarRenderOptions) -> MenuBarLabelContent {
        let fraction = primaryFraction(for: s)
        let composed = composedContent(for: s, style: style, options: options)
        return makeContent(for: s, style: style, options: options, fraction: fraction, composed: composed)
    }

    // The stacked label marks its second line with a glyph (fan / bolt) instead of a unit.
    private func makeContent(for s: MenuBarSnapshot, style: MenuBarStyle, options: MenuBarRenderOptions, fraction: Double,
                             composed: (layout: ComposedLayout?, values: [ComposedValueContent])) -> MenuBarLabelContent {
        let primary = s.resolvedPrimary, secondary = s.resolvedSecondary
        return MenuBarLabelContent(
            style: style, primaryText: Self.text(primary, unit: s.unit, withUnit: false, gauge: style == .gauge), primaryKind: primary.kind,
            secondaryText: Self.text(secondary, unit: s.unit, withUnit: false, gauge: false), secondaryKind: secondary.kind,
            widthKey: ThermikFormat.rpmUnit + "|" + ThermikFormat.wattUnit + "|" + String(localized: "Off"),
            fraction: (fraction * 50).rounded() / 50, tint: tint(for: fraction, snapshot: s, options: options),
            alert: s.alert, stale: s.stale, badge: s.badge, template: !usesColor(s, options: options) && s.badge == .none,
            dark: usesColor(s, options: options) || s.badge != .none ? Self.isDarkAppearance(options.appearance) : false,
            colorBlind: options.colorBlind, spark: style == .sparkline ? Self.sparkPoints(s.history, kind: primary.kind) : [],
            composedLayout: composed.layout, composed: composed.values)
    }

    private func primaryFraction(for s: MenuBarSnapshot) -> Double {
        switch s.resolvedPrimary {
        case .temperature(let c, let scale): scale.normalized(c)
        case .rpm, .watts, .unavailable, .none: min(max(s.normalized, 0), 1)
        }
    }

    private func usesColor(_ s: MenuBarSnapshot, options: MenuBarRenderOptions) -> Bool {
        options.colored || (options.alertColor && s.alert)
    }

    private func tint(for fraction: Double, snapshot s: MenuBarSnapshot, options: MenuBarRenderOptions) -> Double? {
        guard usesColor(s, options: options) else { return nil }
        return (fraction * 50).rounded() / 50
    }

    private static func isDarkAppearance(_ appearance: NSAppearance.Name) -> Bool {
        appearance == .darkAqua || appearance == .vibrantDark || appearance == .accessibilityHighContrastDarkAqua
            || appearance == .accessibilityHighContrastVibrantDark
    }

    private func composedContent(for s: MenuBarSnapshot, style: MenuBarStyle, options: MenuBarRenderOptions)
            -> (layout: ComposedLayout?, values: [ComposedValueContent]) {
        guard let comp = s.composition, style.isComposed else { return (nil, []) }
        let layout = ComposedLayout(layout: comp.layout, size: comp.size, bold: comp.bold, separator: comp.separator,
                                    badge: comp.badge, tintIcons: comp.tintIcons)
        return (layout, s.composed.map { composedValue($0, snapshot: s, options: options) })
    }

    private func composedValue(_ v: MenuBarComposedValue, snapshot s: MenuBarSnapshot,
                               options: MenuBarRenderOptions) -> ComposedValueContent {
        ComposedValueContent(
            text: Self.text(v.reading, unit: s.unit, withUnit: v.showUnit, gauge: false), kind: v.reading.kind,
            showUnit: v.showUnit, symbol: v.symbol, graphic: v.graphic, caption: v.caption,
            tint: composedTint(for: v.reading, snapshot: s, options: options),
            fraction: (min(max(v.fraction, 0), 1) * 50).rounded() / 50,
            spark: v.graphic == .graph ? Self.sparkPoints(v.history, kind: v.reading.kind) : [])
    }

    private func composedTint(for reading: MenuBarReading, snapshot s: MenuBarSnapshot,
                              options: MenuBarRenderOptions) -> Double? {
        guard usesColor(s, options: options), case .temperature(let c, let scale) = reading else { return nil }
        return (scale.normalized(c) * 50).rounded() / 50
    }

    /// Auto-ranged 0…1 points; a minimum span (4 °C, 300 rpm) keeps sensor noise from looking like a trend.
    static func sparkPoints(_ values: [Double], kind: MenuBarReadingKind) -> [Double] {
        let v = values.filter(\.isFinite)
        guard v.count >= 2, let lo = v.min(), let hi = v.max() else { return [] }
        let span = max(hi - lo, kind == .rpm ? 300 : 4)
        let floor = (lo + hi) / 2 - span / 2
        return v.map { (min(max(($0 - floor) / span, 0), 1) * 40).rounded() / 40 }
    }

    /// Visible text of one slot. Numbers never go through LocalizedStringKey (no "1 840" grouping).
    static func text(_ r: MenuBarReading, unit: UnitTemperature, withUnit: Bool, gauge: Bool) -> String {
        switch r {
        case .temperature(let c, _):
            return gauge ? String(ThermikFormat.degrees(c, unit: unit)) : ThermikFormat.temp(c, unit: unit)
        case .rpm(let rpm):
            guard let rounded = roundedRPM(rpm) else { return String(localized: "Off") }
            return withUnit ? rounded + "\u{202F}" + ThermikFormat.rpmUnit : rounded
        case .watts(let w): return ThermikFormat.wattsShort(w)
        case .unavailable(let k): return k == .none ? "" : "—"
        case .none: return ""
        }
    }

    private static func roundedRPM(_ rpm: Double) -> String? {
        guard rpm > 50 else { return nil }
        return ThermikFormat.rpm((rpm / 10).rounded() * 10)
    }

    // MARK: Drawing

    /// Sized for the macOS 26+ menu bar: a 24 pt item on a 30 pt bar next to 13 pt system text. The original 10 / 8.5 pt
    /// stacked fonts read as a smudge beside the clock.
    @MainActor private enum Fonts {
        static let single = ThermikFont.roundedMonoDigits(size: 13, weight: .semibold)
        static let top = ThermikFont.roundedMonoDigits(size: 11.5, weight: .bold)
        static let bottom = ThermikFont.roundedMonoDigits(size: 9.5, weight: .semibold)
        static let pill = ThermikFont.roundedMonoDigits(size: 12, weight: .bold)
        static let gauge = ThermikFont.roundedMonoDigits(size: 9, weight: .bold)
        static let gaugeSmall = ThermikFont.roundedMonoDigits(size: 7.5, weight: .bold)
    }

    private static let height = ThermikMetrics.menuBarContentHeight
    private static let badgeColumn: CGFloat = 8

    /// Reserved width of a slot: the widest text its kind can show (monospaced digits → "888°" covers 0…999°).
    private func slotWidth(_ kind: MenuBarReadingKind, font: NSFont, withUnit: Bool, actual: String) -> CGFloat {
        let key = "\(kind)|\(font.pointSize)|\(font.fontName)|\(withUnit)|\(ThermikFormat.rpmUnit)|\(ThermikFormat.wattUnit)"
        if let reserved = widths[key] { return ceil(max(reserved, Self.measure(actual, font))) }
        let rpm = [withUnit ? "8888\u{202F}" + ThermikFormat.rpmUnit : "8888", String(localized: "Off")]
        let reserved = reservedWidth(key: key, templates: Self.widthTemplates(kind, rpm: rpm), font: font)
        return ceil(max(reserved, Self.measure(actual, font)))
    }

    private func reservedWidth(key: String, templates: [String], font: NSFont) -> CGFloat {
        let reserved = templates.map { Self.measure($0, font) }.max() ?? 0
        widths[key] = reserved
        return reserved
    }

    private static func widthTemplates(_ kind: MenuBarReadingKind, rpm: [String]) -> [String] {
        // Two digits: 100 °C+ (or °F) widens the item once instead of padding every label with an empty column.
        switch kind {
        case .temperature: ["88°"]
        case .rpm: rpm
        case .watts: ["888" + ThermikFormat.wattUnit]
        case .none: []
        }
    }

    private static func measure(_ s: String, _ font: NSFont) -> CGFloat {
        s.isEmpty ? 0 : NSAttributedString(string: s, attributes: [.font: font]).size().width
    }

    private func draw(_ c: MenuBarLabelContent, scales: [CGFloat]) -> NSImage {
        DrawingSession(renderer: self, content: c).draw(scales: scales)
    }

    @MainActor private final class DrawingSession {
        typealias Operation = (NSRect) -> Void
        typealias StackedLines = (top: NSAttributedString, bottom: NSAttributedString, glyph: String?, glyphW: CGFloat, glyphGap: CGFloat)

        static let pad: CGFloat = 1
        let renderer: MenuBarLabelRenderer
        let c: MenuBarLabelContent
        let ramp: ThermikRamp
        let appearance: NSAppearance?
        let base: NSColor
        let tint: NSColor
        var ops: [Operation] = []          // drawing closures in label coordinates (origin bottom-left)
        var width: CGFloat = 0
        var stale: String { c.stale ? "·" : "" }
        var accent: NSColor { c.tint != nil ? tint : base }  // rings, bars and graphs follow the value colour
        var fraction: Double { c.fraction }

        init(renderer: MenuBarLabelRenderer, content: MenuBarLabelContent) {
            let ramp = ThermikRamp.forSettings(colorBlind: content.colorBlind)
            let base: NSColor = content.template ? .black : MenuBarLabelRenderer.resolved(.labelColor, dark: content.dark)
            self.renderer = renderer
            self.c = content
            self.ramp = ramp
            self.appearance = NSAppearance(named: content.dark ? .darkAqua : .aqua)
            // Template images are pure alpha masks; colour images resolve label colour and inks for the bar appearance.
            self.base = base
            self.tint = content.tint.map { ramp.nsInk($0, dark: content.dark) } ?? base
        }

        func draw(scales: [CGFloat]) -> NSImage {
            drawStyle()
            drawBadge()
            let size = NSSize(width: ceil(width + 2 * Self.pad), height: MenuBarLabelRenderer.height)
            let img = NSImage(size: size)
            for scale in scales { addRepresentation(to: img, size: size, scale: scale) }
            img.isTemplate = c.template
            return img
        }

        func text(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }

        /// Text is positioned by its baseline so cap height, not the line box, is centred. Half-point steps stay crisp at 2×.
        static func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }

        static func centredBaseline(_ font: NSFont) -> CGFloat {
            snap((MenuBarLabelRenderer.height - font.capHeight) / 2)
        }

        func put(_ a: NSAttributedString, _ font: NSFont, x: CGFloat, baseline: CGFloat) {
            ops.append { _ in a.draw(at: NSPoint(x: x, y: baseline + font.descender)) }
        }

        /// The common single-line layout: optional accessory, then the value centred in its non-jittering reserved slot.
        func valueAfter(accessory accessoryWidth: CGFloat, gap: CGFloat, _ drawAccessory: Operation? = nil) {
            let s = c.primaryText + stale
            let a = text(s, Fonts.single, tint)
            let w = renderer.slotWidth(c.primaryKind, font: Fonts.single, withUnit: false, actual: s)
            let x0 = Self.pad + accessoryWidth + (accessoryWidth > 0 ? gap : 0)
            width = x0 - Self.pad + w
            if let drawAccessory { ops.append(drawAccessory) }
            put(a, Fonts.single, x: x0 + Self.snap((w - a.size().width) / 2), baseline: Self.centredBaseline(Fonts.single))
        }

        func drawStyle() {
            switch c.style {
            case .iconOnly: drawIconOnly()
            case .temp: valueAfter(accessory: 0, gap: 0)
            case .iconTemp: drawIconTemp()
            case .chip: drawChip()
            case .tempFan: drawTempFan()
            case .stacked: drawStacked()
            default: drawAccessoryStyle()
            }
        }

        func drawAccessoryStyle() {
            switch c.style {
            case .pill: drawPill()
            case .ringTemp: drawRingTemp()
            case .bar: drawBar()
            case .sparkline: drawSparkline()
            default: drawGaugeOrComposed()
            }
        }

        func drawGaugeOrComposed() {
            switch c.style {
            case .gauge: drawGauge()
            case .iconTempFan, .chipTempFan, .flameTempFan, .stackedIcons, .stackedUnits, .tempRPM, .compact, .badgeFan, .ringFan,
                 .cpuGpu, .cpuGpuStacked, .fanOnly, .custom: drawComposed()
            default: break
            }
        }

        func drawIconOnly() {
            let glyph = c.alert ? "thermometer.high" : "thermometer.medium"
            let color = accent, rect = NSRect(x: Self.pad, y: 0, width: 18, height: MenuBarLabelRenderer.height)
            width = 18
            ops.append { _ in MenuBarLabelRenderer.drawSymbol(glyph, size: 15, weight: .medium, color: color, in: rect) }
        }

        func drawIconTemp() {
            let color = base, rect = NSRect(x: Self.pad, y: 0, width: 11, height: MenuBarLabelRenderer.height)
            valueAfter(accessory: 11, gap: 2) { _ in
                MenuBarLabelRenderer.drawSymbol("thermometer.medium", size: 14, weight: .medium, color: color, in: rect)
            }
        }

        func drawChip() {
            let color = base, rect = NSRect(x: Self.pad, y: 0, width: 17, height: MenuBarLabelRenderer.height)
            valueAfter(accessory: 17, gap: 3) { _ in
                MenuBarLabelRenderer.drawSymbol("cpu", size: 15, weight: .regular, color: color, in: rect)
            }
        }

        func drawTempFan() {
            valueAfter(accessory: 0, gap: 0)
            guard c.secondaryKind != .none else { return }
            drawTempFanSecondary()
        }

        func drawTempFanSecondary() {
            let b = text(c.secondaryText, Fonts.single, base)
            let w2 = renderer.slotWidth(c.secondaryKind, font: Fonts.single, withUnit: false, actual: c.secondaryText)
            let glyph = MenuBarLabelRenderer.glyph(for: c.secondaryKind) ?? "thermometer.medium"
            let x0 = Self.pad + width + 6
            let color = base, rect = NSRect(x: x0, y: 0, width: 13, height: MenuBarLabelRenderer.height)
            width = x0 - Self.pad + 13 + 2 + w2
            ops.append { _ in MenuBarLabelRenderer.drawSymbol(glyph, size: 11, weight: .medium, color: color, in: rect) }
            put(b, Fonts.single, x: x0 + 15 + Self.snap((w2 - b.size().width) / 2), baseline: Self.centredBaseline(Fonts.single))
        }

        func drawStacked() {
            // Nothing for the second line: one vertically centred value.
            guard c.secondaryKind != .none else { valueAfter(accessory: 0, gap: 0); return }
            drawStackedLines()
        }

        func prepareStackedLines() -> StackedLines {
            let top = c.primaryText + stale
            let a = text(top, Fonts.top, tint), b = text(c.secondaryText, Fonts.bottom, base)
            // A small glyph names the second line, so no unit is needed.
            let glyph = MenuBarLabelRenderer.glyph(for: c.secondaryKind)
            let glyphW: CGFloat = glyph == nil ? 0 : 8.5, glyphGap: CGFloat = glyph == nil ? 0 : 1.5
            let w1 = renderer.slotWidth(c.primaryKind, font: Fonts.top, withUnit: false, actual: top)
            let w2 = glyphW + glyphGap + renderer.slotWidth(c.secondaryKind, font: Fonts.bottom, withUnit: false, actual: c.secondaryText)
            width = max(w1, w2)
            return (a, b, glyph, glyphW, glyphGap)
        }

        /// Both cap heights plus the gap form one centred block; each line is centred horizontally.
        func drawStackedLines() {
            let lines = prepareStackedLines(), gap: CGFloat = 2.5
            let block = Fonts.top.capHeight + gap + Fonts.bottom.capHeight
            let bottom = Self.snap((MenuBarLabelRenderer.height - block) / 2), top = Self.snap(bottom + Fonts.bottom.capHeight + gap)
            put(lines.top, Fonts.top, x: Self.pad + Self.snap((width - lines.top.size().width) / 2), baseline: top)
            let lineW = lines.glyphW + lines.glyphGap + lines.bottom.size().width
            let x2 = Self.pad + Self.snap((width - lineW) / 2)
            drawStackedGlyph(lines.glyph, x: x2, baseline: bottom, width: lines.glyphW)
            put(lines.bottom, Fonts.bottom, x: x2 + lines.glyphW + lines.glyphGap, baseline: bottom)
        }

        func drawStackedGlyph(_ glyph: String?, x: CGFloat, baseline: CGFloat, width: CGFloat) {
            guard let glyph else { return }
            let color = base, rect = NSRect(x: x, y: baseline, width: width, height: Fonts.bottom.capHeight)
            ops.append { _ in MenuBarLabelRenderer.drawSymbol(glyph, size: 7.5, weight: .bold, color: color, in: rect) }
        }

        /// The value is knocked out of a filled rounded badge, like the input-source badge beside it.
        func drawPill() {
            let s = c.primaryText + stale, a = text(s, Fonts.pill, .black)
            let w = renderer.slotWidth(c.primaryKind, font: Fonts.pill, withUnit: false, actual: s), padX: CGFloat = 5, h: CGFloat = 17
            let r = NSRect(x: Self.pad, y: Self.snap((MenuBarLabelRenderer.height - h) / 2), width: w + 2 * padX, height: h)
            let point = NSPoint(x: r.minX + padX + Self.snap((w - a.size().width) / 2),
                                y: Self.centredBaseline(Fonts.pill) + Fonts.pill.descender)
            let color = accent
            width = w + 2 * padX
            ops.append { _ in Self.drawPillBadge(rect: r, text: a, point: point, color: color) }
        }

        static func drawPillBadge(rect: NSRect, text: NSAttributedString, point: NSPoint, color: NSColor) {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            text.draw(at: point)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }

        func drawRingTemp() {
            let d: CGFloat = 15, color = accent, value = fraction
            let rect = NSRect(x: Self.pad + 1, y: Self.snap((MenuBarLabelRenderer.height - d) / 2) + 1, width: d - 2, height: d - 2)
            valueAfter(accessory: d, gap: 4) { _ in Self.strokeRing(in: rect, lineWidth: 2, color: color, fraction: value) }
        }

        /// A vertical level like a tiny battery: filled from the bottom by the value's place on its scale.
        func drawBar() {
            let bw: CGFloat = 6, bh: CGFloat = 16, color = accent, value = fraction
            let rect = NSRect(x: Self.pad + 0.5, y: Self.snap((MenuBarLabelRenderer.height - bh) / 2) + 0.5, width: bw - 1, height: bh - 1)
            valueAfter(accessory: bw, gap: 4) { _ in Self.drawLevel(in: rect, color: color, fraction: value) }
        }

        /// The last 5 minutes as a line with a faint area; a flat dim line until two samples exist.
        func drawSparkline() {
            let gw: CGFloat = 26, gh: CGFloat = 13, points = c.spark, color = accent
            let rect = NSRect(x: Self.pad, y: Self.snap((MenuBarLabelRenderer.height - gh) / 2), width: gw, height: gh)
            valueAfter(accessory: gw, gap: 4) { _ in Self.drawSparklineAccessory(points: points, rect: rect, color: color) }
        }

        static func drawSparklineAccessory(points: [Double], rect: NSRect, color: NSColor) {
            let line = sparkPath(in: rect, points: points)
            guard points.count >= 2 else { strokeFlatSparkline(line, color: color); return }
            fillSparkArea(line, rect: rect, color: color)
            strokeSparkline(line, color: color)
        }

        static func sparkPath(in rect: NSRect, points: [Double]) -> NSBezierPath {
            guard points.count >= 2 else { return flatSparkPath(in: rect) }
            let line = NSBezierPath(), step = rect.width / CGFloat(points.count - 1)
            for (i, p) in points.enumerated() { addSparkPoint(to: line, rect: rect, index: i, point: p, step: step) }
            return line
        }

        static func flatSparkPath(in rect: NSRect) -> NSBezierPath {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX, y: rect.midY))
            line.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            return line
        }

        static func addSparkPoint(to line: NSBezierPath, rect: NSRect, index: Int, point: Double, step: CGFloat) {
            let pt = NSPoint(x: rect.minX + CGFloat(index) * step, y: rect.minY + 1 + CGFloat(point) * (rect.height - 2))
            if index == 0 { line.move(to: pt) } else { line.line(to: pt) }
        }

        static func strokeFlatSparkline(_ line: NSBezierPath, color: NSColor) {
            line.lineWidth = 1.5
            color.withAlphaComponent(0.35).setStroke()
            line.stroke()
        }

        static func fillSparkArea(_ line: NSBezierPath, rect: NSRect, color: NSColor) {
            guard let area = line.copy() as? NSBezierPath else { return }
            area.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            area.line(to: NSPoint(x: rect.minX, y: rect.minY))
            area.close()
            color.withAlphaComponent(0.22).setFill()
            area.fill()
        }

        static func strokeSparkline(_ line: NSBezierPath, color: NSColor) {
            line.lineWidth = 1.5
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            color.setStroke()
            line.stroke()
        }

        static func drawComposedGraph(points: [Double], rect: NSRect, color: NSColor) {
            let line = sparkPath(in: rect, points: points)
            let stroke = points.count >= 2 ? color : color.withAlphaComponent(0.35)
            strokeSparkline(line, color: stroke)
        }

        static func strokeRing(in rect: NSRect, lineWidth: CGFloat, color: NSColor, fraction: Double) {
            strokeRingTrack(in: rect, lineWidth: lineWidth, color: color)
            guard fraction > 0 else { return }
            strokeRingArc(in: rect, lineWidth: lineWidth, color: color, fraction: fraction)
        }

        static func strokeRingTrack(in rect: NSRect, lineWidth: CGFloat, color: NSColor) {
            let track = NSBezierPath(ovalIn: rect)
            track.lineWidth = lineWidth
            color.withAlphaComponent(0.3).setStroke()
            track.stroke()
        }

        static func strokeRingArc(in rect: NSRect, lineWidth: CGFloat, color: NSColor, fraction: Double) {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
        }

        static func drawLevel(in rect: NSRect, color: NSColor, fraction: Double) {
            strokeLevelOutline(in: rect, color: color)
            fillLevel(in: rect, color: color, fraction: fraction)
        }

        static func strokeLevelOutline(in rect: NSRect, color: NSColor) {
            let outline = NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2)
            outline.lineWidth = 1.1
            color.withAlphaComponent(0.55).setStroke()
            outline.stroke()
        }

        static func fillLevel(in rect: NSRect, color: NSColor, fraction: Double) {
            let inner = rect.insetBy(dx: 1.5, dy: 1.5)
            let fill = NSRect(x: inner.minX, y: inner.minY, width: inner.width,
                              height: max(inner.height * max(fraction, 0.1), inner.width))
            color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: inner.width / 2, yRadius: inner.width / 2).fill()
        }

        func drawGauge() {
            let d: CGFloat = 20, font = c.primaryText.count > 2 ? Fonts.gaugeSmall : Fonts.gauge
            let a = text(c.primaryText, font, base), color = accent, value = fraction
            let rect = NSRect(x: Self.pad + 1, y: Self.snap((MenuBarLabelRenderer.height - d) / 2) + 1, width: d - 2, height: d - 2)
            width = d + (stale.isEmpty ? 0 : 4)
            ops.append { _ in Self.strokeRing(in: rect, lineWidth: 2.2, color: color, fraction: value) }
            put(a, font, x: Self.pad + Self.snap((d - a.size().width) / 2), baseline: Self.centredBaseline(font))
            guard !stale.isEmpty else { return }
            put(text(stale, Fonts.single, base), Fonts.single, x: Self.pad + d, baseline: Self.centredBaseline(Fonts.single))
        }

        func drawComposed() {
            guard let layout = c.composedLayout, !c.composed.isEmpty else { valueAfter(accessory: 0, gap: 0); return }
            ComposedDrawing(session: self, layout: layout, items: c.composed).draw()
        }

        func drawBadge() {
            guard c.badge != .none else { return }
            let x = Self.pad + width + 1
            let (glyph, color): (String, NSColor) = c.badge == .safety
                ? ("exclamationmark.circle.fill", ramp.nsInk(1, dark: c.dark))
                : ("diamond.fill", MenuBarLabelRenderer.resolved(.controlAccentColor, dark: c.dark))
            let size: CGFloat = c.badge == .safety ? 7 : 6
            let rect = NSRect(x: x, y: MenuBarLabelRenderer.height - 9, width: 6, height: 7)
            ops.append { _ in MenuBarLabelRenderer.drawSymbol(glyph, size: size, weight: .bold, color: color, in: rect) }
            width += MenuBarLabelRenderer.badgeColumn
        }

        func addRepresentation(to img: NSImage, size: NSSize, scale: CGFloat) {
            guard let rep = Self.bitmapRep(size: size, scale: scale), render(into: rep, size: size) else { return }
            img.addRepresentation(rep)
        }

        static func bitmapRep(size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                                             pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            // Set the point size BEFORE creating the context, or a 2× rep draws half-size in the bottom-left corner.
            rep.size = size
            return rep
        }

        func render(into rep: NSBitmapImageRep, size: NSSize) -> Bool {
            guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            performDrawing(in: NSRect(origin: .zero, size: size))
            ctx.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }

        func performDrawing(in rect: NSRect) {
            let operations = ops
            if let appearance { appearance.performAsCurrentDrawingAppearance { operations.forEach { $0(rect) } } }
            else { operations.forEach { $0(rect) } }
        }
    }

    /// Composed labels: values with optional glyph / graphic and caption, in one row or columns of two rows;
    /// optionally all knocked out of one rounded badge. Measurement and drawing are separate named operations.
    @MainActor private final class ComposedDrawing {
        typealias Baselines = (top: CGFloat, bottom: CGFloat)

        struct ValueLayout {
            var accessory: CGFloat
            var caption: CGFloat
            var slot: CGFloat
            var baseline: CGFloat
            var mid: CGFloat
            var width: CGFloat { accessory + caption + slot }
        }

        let session: DrawingSession
        let layout: ComposedLayout
        let items: [ComposedValueContent]
        let font: NSFont
        let captionFont: NSFont
        let symbolSize: CGFloat
        var stacked: Bool { layout.layout == .stacked }
        var symbolW: CGFloat { (symbolSize * 1.2).rounded() }
        var padX: CGFloat { layout.badge ? 5 : 0 }
        var cap: CGFloat { font.capHeight }
        var knockout: Bool { layout.badge }

        init(session: DrawingSession, layout: ComposedLayout, items: [ComposedValueContent]) {
            let size = Self.fontSize(for: layout)
            self.session = session
            self.layout = layout
            self.items = items
            self.font = ThermikFont.roundedMonoDigits(size: size, weight: layout.bold ? .bold : .medium)
            self.captionFont = ThermikFont.roundedMonoDigits(size: (size * 0.82).rounded(), weight: .semibold)
            self.symbolSize = layout.layout == .stacked ? (size * 0.8).rounded() : size
        }

        static func fontSize(for layout: ComposedLayout) -> CGFloat {
            switch (layout.layout == .stacked, layout.size) {
            case (false, .small): 11; case (false, .medium): 13; case (false, .large): 14.5
            case (true, .small): 9.5; case (true, .medium): 10.5; case (true, .large): 11.5
            }
        }

        func draw() {
            let firstOp = session.ops.count
            var x = DrawingSession.pad + padX
            if stacked { x = drawStackedItems(from: x) } else { x = drawRowItems(from: x) }
            session.width = x - DrawingSession.pad + padX
            addBadge(firstOp: firstOp)
        }

        func drawRowItems(from start: CGFloat) -> CGFloat {
            var x = start
            for (i, item) in items.enumerated() {
                if i > 0 { x += separator(at: x) }
                x += drawValue(item, x0: x, baseline: nil)
            }
            return x
        }

        /// Columns of two: values 1 over 2, 3 over 4. Both lines use the same font and are centred in their column.
        func drawStackedItems(from start: CGFloat) -> CGFloat {
            var x = start
            let baselines = stackedBaselines()
            for (col, start) in stride(from: 0, to: items.count, by: 2).enumerated() {
                if col > 0 { x += separator(at: x) }
                x += drawStackedColumn(at: x, start: start, baselines: baselines)
            }
            return x
        }

        func stackedBaselines() -> Baselines {
            let gap: CGFloat = 2.5
            let bottom = DrawingSession.snap((MenuBarLabelRenderer.height - (2 * cap + gap)) / 2)
            return (DrawingSession.snap(bottom + cap + gap), bottom)
        }

        func drawStackedColumn(at x: CGFloat, start: Int, baselines: Baselines) -> CGFloat {
            let top = items[start], bottom = start + 1 < items.count ? items[start + 1] : nil
            let wTop = measureValue(top, baseline: baselines.top)
            let wBottom = bottom.map { measureValue($0, baseline: baselines.bottom) } ?? 0
            let columnWidth = max(wTop, wBottom)
            drawStackedValues(top: top, bottom: bottom, x: x, columnWidth: columnWidth, widths: (wTop, wBottom), baselines: baselines)
            return columnWidth
        }

        func drawStackedValues(top: ComposedValueContent, bottom: ComposedValueContent?, x: CGFloat, columnWidth: CGFloat,
                               widths: (top: CGFloat, bottom: CGFloat), baselines: Baselines) {
            guard let bottom else { drawValue(top, x0: x, baseline: nil); return }  // a lone value sits on the centre line
            drawValue(top, x0: x + DrawingSession.snap((columnWidth - widths.top) / 2), baseline: baselines.top)
            drawValue(bottom, x0: x + DrawingSession.snap((columnWidth - widths.bottom) / 2), baseline: baselines.bottom)
        }

        func measureValue(_ item: ComposedValueContent, baseline: CGFloat?) -> CGFloat {
            valueLayout(item, baseline: baseline).width
        }

        /// One value's glyph/graphic, caption and number widths; `mid` is the vertical centre of the digits.
        func valueLayout(_ item: ComposedValueContent, baseline: CGFloat?) -> ValueLayout {
            let accessory = accessoryWidth(for: item), caption = captionWidth(for: item)
            let slot = session.renderer.slotWidth(item.kind, font: font, withUnit: item.showUnit, actual: item.text)
            let baseline = baseline ?? DrawingSession.centredBaseline(font)
            return ValueLayout(accessory: accessory, caption: caption, slot: slot, baseline: baseline, mid: baseline + cap / 2)
        }

        func accessoryWidth(for item: ComposedValueContent) -> CGFloat {
            guard !stacked, item.graphic != .none else { return symbolWidth(for: item) }
            return graphicWidth(for: item.graphic)
        }

        func symbolWidth(for item: ComposedValueContent) -> CGFloat {
            guard item.symbol != nil else { return 0 }
            return symbolW + (stacked ? 1.5 : 2)
        }

        func graphicWidth(for graphic: MenuBarIcon) -> CGFloat {
            switch graphic {
            case .ring: (cap * 1.9).rounded() + 4
            case .level: 10
            case .graph: 28
            default: 0
            }
        }

        func captionWidth(for item: ComposedValueContent) -> CGFloat {
            guard !item.caption.isEmpty else { return 0 }
            let a = session.text(item.caption, captionFont, session.base.withAlphaComponent(knockout ? 1 : 0.72))
            return ceil(a.size().width) + 3
        }

        @discardableResult
        func drawValue(_ item: ComposedValueContent, x0: CGFloat, baseline: CGFloat?) -> CGFloat {
            let metrics = valueLayout(item, baseline: baseline)
            let valueInk = ink(item), iconInk = layout.tintIcons ? valueInk : session.base
            drawAccessory(item, metrics: metrics, x0: x0, color: iconInk)
            drawCaption(item, metrics: metrics, x0: x0)
            drawValueText(item, metrics: metrics, x0: x0, color: valueInk)
            return metrics.width
        }

        func ink(_ item: ComposedValueContent) -> NSColor {
            item.tint.map { session.ramp.nsInk($0, dark: session.c.dark) } ?? session.base
        }

        func drawAccessory(_ item: ComposedValueContent, metrics: ValueLayout, x0: CGFloat, color: NSColor) {
            if !stacked, item.graphic != .none { drawGraphic(item, metrics: metrics, x0: x0, color: color); return }
            guard let symbol = item.symbol else { return }
            drawSymbolAccessory(symbol, metrics: metrics, x0: x0, color: color)
        }

        func drawGraphic(_ item: ComposedValueContent, metrics: ValueLayout, x0: CGFloat, color: NSColor) {
            switch item.graphic {
            case .ring: drawRingGraphic(item, metrics: metrics, x0: x0, color: color)
            case .level: drawLevelGraphic(item, metrics: metrics, x0: x0, color: color)
            case .graph: drawGraphGraphic(item, metrics: metrics, x0: x0, color: color)
            default: break
            }
        }

        func drawRingGraphic(_ item: ComposedValueContent, metrics: ValueLayout, x0: CGFloat, color: NSColor) {
            let d = (cap * 1.9).rounded(), value = item.fraction
            let rect = NSRect(x: x0 + 1, y: DrawingSession.snap(metrics.mid - d / 2) + 1, width: d - 2, height: d - 2)
            session.ops.append { _ in DrawingSession.strokeRing(in: rect, lineWidth: 2, color: color, fraction: value) }
        }

        func drawLevelGraphic(_ item: ComposedValueContent, metrics: ValueLayout, x0: CGFloat, color: NSColor) {
            let bw: CGFloat = 6, bh = (cap * 1.9).rounded(), value = item.fraction
            let rect = NSRect(x: x0 + 0.5, y: DrawingSession.snap(metrics.mid - bh / 2) + 0.5, width: bw - 1, height: bh - 1)
            session.ops.append { _ in DrawingSession.drawLevel(in: rect, color: color, fraction: value) }
        }

        func drawGraphGraphic(_ item: ComposedValueContent, metrics: ValueLayout, x0: CGFloat, color: NSColor) {
            let gw: CGFloat = 24, gh = (cap * 1.5).rounded(), points = item.spark
            let rect = NSRect(x: x0, y: DrawingSession.snap(metrics.mid - gh / 2), width: gw, height: gh)
            session.ops.append { _ in DrawingSession.drawComposedGraph(points: points, rect: rect, color: color) }
        }

        func drawSymbolAccessory(_ symbol: String, metrics: ValueLayout, x0: CGFloat, color: NSColor) {
            let rect = NSRect(x: x0, y: DrawingSession.snap(metrics.mid - symbolW / 2), width: symbolW, height: symbolW)
            let weight: NSFont.Weight = layout.bold ? .semibold : .medium, cutsOut = knockout, size = symbolSize
            session.ops.append { _ in
                MenuBarLabelRenderer.drawSymbol(symbol, size: size, weight: weight, color: color, in: rect, knockout: cutsOut)
            }
        }

        func drawCaption(_ item: ComposedValueContent, metrics: ValueLayout, x0: CGFloat) {
            guard !item.caption.isEmpty else { return }
            let a = session.text(item.caption, captionFont, session.base.withAlphaComponent(knockout ? 1 : 0.72))
            session.put(a, captionFont, x: x0 + metrics.accessory, baseline: metrics.baseline)
        }

        func drawValueText(_ item: ComposedValueContent, metrics: ValueLayout, x0: CGFloat, color: NSColor) {
            let value = session.text(item.text, font, color)
            let x = x0 + metrics.accessory + metrics.caption + DrawingSession.snap((metrics.slot - value.size().width) / 2)
            session.put(value, font, x: x, baseline: metrics.baseline)
        }

        /// Gap (and mark) between two values or columns; returns its width.
        func separator(at x: CGFloat) -> CGFloat {
            switch layout.separator {
            case .space: 7
            case .dot: dotSeparator(at: x)
            case .bar: barSeparator(at: x)
            }
        }

        func dotSeparator(at x: CGFloat) -> CGFloat {
            let dot = session.text("·", font, session.base.withAlphaComponent(knockout ? 1 : 0.6))
            session.put(dot, font, x: x + 2.5, baseline: DrawingSession.centredBaseline(font))
            return ceil(dot.size().width) + 5
        }

        func barSeparator(at x: CGFloat) -> CGFloat {
            let h = stacked ? MenuBarLabelRenderer.height - 6 : (cap * 1.6).rounded()
            let rect = NSRect(x: x + 4.5, y: DrawingSession.snap((MenuBarLabelRenderer.height - h) / 2), width: 1, height: h)
            let color = session.base.withAlphaComponent(knockout ? 1 : 0.4)
            session.ops.append { _ in color.setFill(); rect.fill() }
            return 10
        }

        /// Badge fill is inserted first; all following value operations cut their shapes out of it.
        func addBadge(firstOp: Int) {
            guard layout.badge else { return }
            let h: CGFloat = stacked ? 21 : 17
            let fill = session.c.composed.first(where: { $0.tint != nil }).flatMap { $0.tint }
                .map { session.ramp.nsInk($0, dark: session.c.dark) } ?? session.base
            let rect = NSRect(x: DrawingSession.pad, y: DrawingSession.snap((MenuBarLabelRenderer.height - h) / 2),
                              width: session.width, height: h)
            session.ops.insert({ _ in Self.drawBadge(rect: rect, color: fill) }, at: firstOp)
            session.ops.append { _ in Self.restoreSourceOver() }
        }

        static func drawBadge(rect: NSRect, color: NSColor) {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
        }

        static func restoreSourceOver() {
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
    }

    /// Glyph that names a secondary reading (the unit is dropped next to it).
    private static func glyph(for kind: MenuBarReadingKind) -> String? {
        switch kind {
        case .rpm: "fan.fill"
        case .watts: "bolt.fill"
        case .temperature, .none: nil
        }
    }

    private static func resolved(_ color: NSColor, dark: Bool) -> NSColor {
        var out = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.deviceRGB) ?? color
        }
        return out
    }

    /// Draws an SF Symbol centred in `rect` in one flat colour: the monochrome glyph is drawn, then re-coloured with
    /// `.sourceAtop` inside its own rect (symbol rects never overlap the text, so nothing else is touched). Palette
    /// colouring would render secondary layers at reduced opacity (grey glyphs next to full-strength digits).
    private static func drawSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, in rect: NSRect,
                                   knockout: Bool = false) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size
        let r = NSRect(x: (rect.midX - s.width / 2).rounded(), y: (rect.midY - s.height / 2).rounded(), width: s.width, height: s.height)
        // Inside a badge the glyph cuts its shape out of the fill instead of being painted.
        guard !knockout else { img.draw(in: r, from: .zero, operation: .destinationOut, fraction: 1); return }
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        r.fill(using: .sourceAtop)
    }
}

/// SwiftUI preview of a label (Settings gallery / onboarding): the exact image the status item shows.
struct CompactLabel: View {
    var snapshot: MenuBarSnapshot
    var style: MenuBarStyle
    var colored: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.thermikRamp) private var ramp

    var body: some View {
        let options = MenuBarRenderOptions(colored: colored, alertColor: true, colorBlind: ramp == .colorBlind,
                                           appearance: scheme == .dark ? .darkAqua : .aqua)
        let img = galleryRenderer.image(for: snapshot, style: style, options: options, scales: [displayScale])
        Image(nsImage: img)
            .renderingMode(img.isTemplate ? .template : .original)
            .foregroundStyle(.primary)
            .frame(height: ThermikMetrics.menuBarContentHeight)
            .accessibilityLabel(Text(img.accessibilityDescription ?? "Thermik"))
    }
}

@MainActor private let galleryRenderer = MenuBarLabelRenderer()
