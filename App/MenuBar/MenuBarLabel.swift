//  MenuBarLabel.swift — status-item label rendering (MIT). OWNER: Unit 7. Kit API (MenuBarSnapshot,
//  MenuBarLabelRenderer.image(for:style:colored:scale:), CompactLabel) is frozen for Unit 8's style gallery.
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
    // Unit 7 additions — defaults keep the original memberwise init `MenuBarSnapshot(celsius:rpm:normalized:alert:)`.
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

    /// Kit API (Unit 0 / Unit 8 gallery): template unless `colored`; drawn for `scale` (and 2×).
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
        let primary = s.resolvedPrimary, secondary = s.resolvedSecondary
        let useColor = options.colored || (options.alertColor && s.alert)
        let dark = options.appearance == .darkAqua || options.appearance == .vibrantDark
            || options.appearance == .accessibilityHighContrastDarkAqua || options.appearance == .accessibilityHighContrastVibrantDark
        var tint: Double?
        var fraction = 0.0
        switch primary {
        case .temperature(let c, let scale):
            let t = scale.normalized(c)
            fraction = t
            if useColor { tint = (t * 50).rounded() / 50 }
        case .rpm, .watts, .unavailable, .none:
            fraction = min(max(s.normalized, 0), 1)
            if useColor { tint = (fraction * 50).rounded() / 50 }
        }
        let template = !useColor && s.badge == .none
        var composedLayout: ComposedLayout?
        var composed: [ComposedValueContent] = []
        if let comp = s.composition, style.isComposed {
            composedLayout = ComposedLayout(layout: comp.layout, size: comp.size, bold: comp.bold, separator: comp.separator,
                                            badge: comp.badge, tintIcons: comp.tintIcons)
            composed = s.composed.map { v in
                var itemTint: Double?
                if useColor, case .temperature(let c, let scale) = v.reading { itemTint = (scale.normalized(c) * 50).rounded() / 50 }
                return ComposedValueContent(
                    text: Self.text(v.reading, unit: s.unit, withUnit: v.showUnit, gauge: false), kind: v.reading.kind,
                    showUnit: v.showUnit, symbol: v.symbol, graphic: v.graphic, caption: v.caption, tint: itemTint,
                    fraction: (min(max(v.fraction, 0), 1) * 50).rounded() / 50,
                    spark: v.graphic == .graph ? Self.sparkPoints(v.history, kind: v.reading.kind) : [])
            }
        }
        return MenuBarLabelContent(
            style: style,
            primaryText: Self.text(primary, unit: s.unit, withUnit: false, gauge: style == .gauge),
            primaryKind: primary.kind,
            // The stacked label marks its second line with a glyph (fan / bolt) instead of a unit.
            secondaryText: Self.text(secondary, unit: s.unit, withUnit: false, gauge: false),
            secondaryKind: secondary.kind,
            widthKey: ThermikFormat.rpmUnit + "|" + ThermikFormat.wattUnit + "|" + String(localized: "Off"),
            fraction: (fraction * 50).rounded() / 50,
            tint: tint, alert: s.alert, stale: s.stale, badge: s.badge, template: template,
            dark: template ? false : dark, colorBlind: options.colorBlind,
            spark: style == .sparkline ? Self.sparkPoints(s.history, kind: primary.kind) : [],
            composedLayout: composedLayout, composed: composed)
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
            guard rpm > 50 else { return String(localized: "Off") }
            let rounded = ThermikFormat.rpm((rpm / 10).rounded() * 10)
            return withUnit ? rounded + "\u{202F}" + ThermikFormat.rpmUnit : rounded
        case .watts(let w):
            return ThermikFormat.wattsShort(w)
        case .unavailable(let k):
            return k == .none ? "" : "—"
        case .none:
            return ""
        }
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
        let reserved: CGFloat
        if let w = widths[key] { reserved = w } else {
            let templates: [String]
            switch kind {
            // Two digits: 100 °C+ (or °F) widens the item once instead of padding every label with an empty column.
            case .temperature: templates = ["88°"]
            case .rpm: templates = [withUnit ? "8888\u{202F}" + ThermikFormat.rpmUnit : "8888", String(localized: "Off")]
            case .watts: templates = ["888" + ThermikFormat.wattUnit]
            case .none: templates = []
            }
            reserved = templates.map { Self.measure($0, font) }.max() ?? 0
            widths[key] = reserved
        }
        return ceil(max(reserved, Self.measure(actual, font)))
    }

    private static func measure(_ s: String, _ font: NSFont) -> CGFloat {
        s.isEmpty ? 0 : NSAttributedString(string: s, attributes: [.font: font]).size().width
    }

    private func draw(_ c: MenuBarLabelContent, scales: [CGFloat]) -> NSImage {
        let ramp = ThermikRamp.forSettings(colorBlind: c.colorBlind)
        let appearance = NSAppearance(named: c.dark ? .darkAqua : .aqua)
        // Template images are pure alpha masks (AppKit tints them for the menu bar); colour images resolve label colour
        // and inks for the menu bar's own appearance.
        let base: NSColor = c.template ? .black : Self.resolved(.labelColor, dark: c.dark)
        let tint: NSColor = c.tint.map { ramp.nsInk($0, dark: c.dark) } ?? base
        let stale = c.stale ? "·" : ""
        let badgeWidth: CGFloat = c.badge == .none ? 0 : Self.badgeColumn
        let pad: CGFloat = 1

        var ops: [(NSRect) -> Void] = []          // drawing closures in label coordinates (origin bottom-left)
        var width: CGFloat = 0

        func text(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }
        /// Text is positioned by its baseline so the digits' cap height — what the eye lines up with the clock — is
        /// centred, not the line box (whose descender space pushed the old labels up). Half-point steps stay crisp at 2×.
        func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
        func centredBaseline(_ font: NSFont) -> CGFloat { snap((Self.height - font.capHeight) / 2) }
        func put(_ a: NSAttributedString, _ font: NSFont, x: CGFloat, baseline: CGFloat) {
            ops.append { _ in a.draw(at: NSPoint(x: x, y: baseline + font.descender)) }
        }
        let accent = c.tint != nil ? tint : base       // rings, bars and graphs follow the value colour when coloured
        let fraction = c.fraction

        /// The common single-line layout: an optional leading accessory, then the primary value centred in its
        /// reserved slot (the slot, not the text, sets the width, so the item never jitters).
        func valueAfter(accessory accessoryWidth: CGFloat, gap: CGFloat, _ drawAccessory: ((NSRect) -> Void)? = nil) {
            let s = c.primaryText + stale
            let a = text(s, Fonts.single, tint)
            let w = slotWidth(c.primaryKind, font: Fonts.single, withUnit: false, actual: s)
            let x0 = pad + accessoryWidth + (accessoryWidth > 0 ? gap : 0)
            width = x0 - pad + w
            if let drawAccessory { ops.append(drawAccessory) }
            put(a, Fonts.single, x: x0 + snap((w - a.size().width) / 2), baseline: centredBaseline(Fonts.single))
        }
        func ring(in rect: NSRect, lineWidth: CGFloat) {
            let track = NSBezierPath(ovalIn: rect)
            track.lineWidth = lineWidth
            accent.withAlphaComponent(0.3).setStroke()
            track.stroke()
            guard fraction > 0 else { return }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            accent.setStroke()
            arc.stroke()
        }

        /// Composed labels: values with optional glyph / graphic and caption, in one row or in columns of two rows;
        /// optionally all knocked out of one rounded badge.
        func composeLabel(_ L: ComposedLayout, _ items: [ComposedValueContent]) {
            let stacked = L.layout == .stacked
            let size: CGFloat = switch (stacked, L.size) {
            case (false, .small): 11; case (false, .medium): 13; case (false, .large): 14.5
            case (true, .small): 9.5; case (true, .medium): 10.5; case (true, .large): 11.5
            }
            let font = ThermikFont.roundedMonoDigits(size: size, weight: L.bold ? .bold : .medium)
            let captionFont = ThermikFont.roundedMonoDigits(size: (size * 0.82).rounded(), weight: .semibold)
            let symbolSize = stacked ? (size * 0.8).rounded() : size
            let symbolW = (symbolSize * 1.2).rounded()
            let padX: CGFloat = L.badge ? 5 : 0
            let cap = font.capHeight
            let knockout = L.badge
            func ink(_ it: ComposedValueContent) -> NSColor { it.tint.map { ramp.nsInk($0, dark: c.dark) } ?? base }

            /// One value (glyph/graphic, caption, number) from x0; `baseline` is the number's; nil → centred line.
            /// Returns the width; draws only when `draw`.
            func value(_ it: ComposedValueContent, x0: CGFloat, baseline: CGFloat?, draw: Bool) -> CGFloat {
                var w: CGFloat = 0
                let valueInk = ink(it), iconInk = L.tintIcons ? valueInk : base
                let b = baseline ?? centredBaseline(font)
                let mid = b + cap / 2                                  // vertical centre of the digits
                if !stacked, it.graphic != .none {
                    let fraction = it.fraction, spark = it.spark
                    switch it.graphic {
                    case .ring:
                        let d = (cap * 1.9).rounded()
                        if draw {
                            let x = x0 + w
                            ops.append { _ in
                                let r = NSRect(x: x + 1, y: snap(mid - d / 2) + 1, width: d - 2, height: d - 2)
                                let track = NSBezierPath(ovalIn: r); track.lineWidth = 2
                                iconInk.withAlphaComponent(0.3).setStroke(); track.stroke()
                                guard fraction > 0 else { return }
                                let arc = NSBezierPath()
                                arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                                              startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                                arc.lineWidth = 2; arc.lineCapStyle = .round; iconInk.setStroke(); arc.stroke()
                            }
                        }
                        w += d + 4
                    case .level:
                        let bw: CGFloat = 6, bh = (cap * 1.9).rounded()
                        if draw {
                            let x = x0 + w
                            ops.append { _ in
                                let r = NSRect(x: x + 0.5, y: snap(mid - bh / 2) + 0.5, width: bw - 1, height: bh - 1)
                                let outline = NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2)
                                outline.lineWidth = 1.1; iconInk.withAlphaComponent(0.55).setStroke(); outline.stroke()
                                let inner = r.insetBy(dx: 1.5, dy: 1.5)
                                let f = NSRect(x: inner.minX, y: inner.minY, width: inner.width,
                                               height: max(inner.height * max(fraction, 0.1), inner.width))
                                iconInk.setFill(); NSBezierPath(roundedRect: f, xRadius: inner.width / 2, yRadius: inner.width / 2).fill()
                            }
                        }
                        w += bw + 4
                    case .graph:
                        let gw: CGFloat = 24, gh = (cap * 1.5).rounded()
                        if draw {
                            let x = x0 + w
                            ops.append { _ in
                                let r = NSRect(x: x, y: snap(mid - gh / 2), width: gw, height: gh)
                                let line = NSBezierPath()
                                if spark.count >= 2 {
                                    let step = r.width / CGFloat(spark.count - 1)
                                    for (i, p) in spark.enumerated() {
                                        let pt = NSPoint(x: r.minX + CGFloat(i) * step, y: r.minY + 1 + CGFloat(p) * (r.height - 2))
                                        if i == 0 { line.move(to: pt) } else { line.line(to: pt) }
                                    }
                                } else {
                                    line.move(to: NSPoint(x: r.minX, y: r.midY)); line.line(to: NSPoint(x: r.maxX, y: r.midY))
                                }
                                line.lineWidth = 1.5; line.lineJoinStyle = .round; line.lineCapStyle = .round
                                (spark.count >= 2 ? iconInk : iconInk.withAlphaComponent(0.35)).setStroke(); line.stroke()
                            }
                        }
                        w += gw + 4
                    default: break
                    }
                } else if let symbol = it.symbol {
                    if draw {
                        let x = x0 + w
                        ops.append { _ in
                            Self.drawSymbol(symbol, size: symbolSize, weight: L.bold ? .semibold : .medium, color: iconInk,
                                            in: NSRect(x: x, y: snap(mid - symbolW / 2), width: symbolW, height: symbolW),
                                            knockout: knockout)
                        }
                    }
                    w += symbolW + (stacked ? 1.5 : 2)
                }
                if !it.caption.isEmpty {
                    let a = text(it.caption, captionFont, base.withAlphaComponent(knockout ? 1 : 0.72))
                    if draw { put(a, captionFont, x: x0 + w, baseline: b) }
                    w += ceil(a.size().width) + 3
                }
                let v = text(it.text, font, valueInk)
                let slot = slotWidth(it.kind, font: font, withUnit: it.showUnit, actual: it.text)
                if draw { put(v, font, x: x0 + w + snap((slot - v.size().width) / 2), baseline: b) }
                return w + slot
            }
            /// Gap (and mark) between two values or columns; returns its width.
            func separator(at x: CGFloat, draw: Bool) -> CGFloat {
                switch L.separator {
                case .space:
                    return 7
                case .dot:
                    let dot = text("·", font, base.withAlphaComponent(knockout ? 1 : 0.6))
                    if draw { put(dot, font, x: x + 2.5, baseline: centredBaseline(font)) }
                    return ceil(dot.size().width) + 5
                case .bar:
                    let h = stacked ? Self.height - 6 : (cap * 1.6).rounded()
                    if draw {
                        ops.append { _ in
                            let r = NSRect(x: x + 4.5, y: snap((Self.height - h) / 2), width: 1, height: h)
                            base.withAlphaComponent(knockout ? 1 : 0.4).setFill(); r.fill()
                        }
                    }
                    return 10
                }
            }

            let firstOp = ops.count
            var x = pad + padX
            if stacked {
                // Columns of two: values 1 over 2, 3 over 4. Both lines use the same font; each is centred in its column.
                let gap: CGFloat = 2.5
                let bottomBaseline = snap((Self.height - (2 * cap + gap)) / 2)
                let topBaseline = snap(bottomBaseline + cap + gap)
                for (col, start) in stride(from: 0, to: items.count, by: 2).enumerated() {
                    if col > 0 { x += separator(at: x, draw: true) }
                    let top = items[start], bottom = start + 1 < items.count ? items[start + 1] : nil
                    let wTop = value(top, x0: 0, baseline: topBaseline, draw: false)
                    let wBottom = bottom.map { value($0, x0: 0, baseline: bottomBaseline, draw: false) } ?? 0
                    let colW = max(wTop, wBottom)
                    if let bottom {
                        _ = value(top, x0: x + snap((colW - wTop) / 2), baseline: topBaseline, draw: true)
                        _ = value(bottom, x0: x + snap((colW - wBottom) / 2), baseline: bottomBaseline, draw: true)
                    } else {
                        _ = value(top, x0: x, baseline: nil, draw: true)          // a lone value sits on the centre line
                    }
                    x += colW
                }
            } else {
                for (i, it) in items.enumerated() {
                    if i > 0 { x += separator(at: x, draw: true) }
                    x += value(it, x0: x, baseline: nil, draw: true)
                }
            }
            width = x - pad + padX
            guard L.badge else { return }
            // Badge: fill first, then everything drawn so far cuts its shape out of the fill.
            let badgeW = width, h: CGFloat = stacked ? 21 : 17
            let fill = c.composed.first(where: { $0.tint != nil }).flatMap { $0.tint }.map { ramp.nsInk($0, dark: c.dark) } ?? base
            ops.insert({ _ in
                fill.setFill()
                NSBezierPath(roundedRect: NSRect(x: pad, y: snap((Self.height - h) / 2), width: badgeW, height: h),
                             xRadius: 5, yRadius: 5).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            }, at: firstOp)
            ops.append { _ in NSGraphicsContext.current?.compositingOperation = .sourceOver }
        }

        switch c.style {
        case .iconOnly:
            let glyph = c.alert ? "thermometer.high" : "thermometer.medium"
            width = 18
            ops.append { _ in Self.drawSymbol(glyph, size: 15, weight: .medium, color: accent, in: NSRect(x: pad, y: 0, width: 18, height: Self.height)) }

        case .temp:
            valueAfter(accessory: 0, gap: 0)

        case .iconTemp:
            valueAfter(accessory: 11, gap: 2) { _ in
                Self.drawSymbol("thermometer.medium", size: 14, weight: .medium, color: base,
                                in: NSRect(x: pad, y: 0, width: 11, height: Self.height))
            }

        case .chip:
            valueAfter(accessory: 17, gap: 3) { _ in
                Self.drawSymbol("cpu", size: 15, weight: .regular, color: base, in: NSRect(x: pad, y: 0, width: 17, height: Self.height))
            }

        case .tempFan:
            valueAfter(accessory: 0, gap: 0)
            if c.secondaryKind != .none {
                let b = text(c.secondaryText, Fonts.single, base)
                let w2 = slotWidth(c.secondaryKind, font: Fonts.single, withUnit: false, actual: c.secondaryText)
                let glyph = Self.glyph(for: c.secondaryKind) ?? "thermometer.medium"
                let x0 = pad + width + 6
                width = x0 - pad + 13 + 2 + w2
                ops.append { _ in Self.drawSymbol(glyph, size: 11, weight: .medium, color: base,
                                                  in: NSRect(x: x0, y: 0, width: 13, height: Self.height)) }
                put(b, Fonts.single, x: x0 + 15 + snap((w2 - b.size().width) / 2), baseline: centredBaseline(Fonts.single))
            }

        case .stacked:
            if c.secondaryKind == .none {
                // Nothing for the second line (fanless, or secondary = none): one vertically centred value.
                valueAfter(accessory: 0, gap: 0)
            } else {
                let top = c.primaryText + stale
                let a = text(top, Fonts.top, tint)
                let b = text(c.secondaryText, Fonts.bottom, base)
                // Second line: a small glyph says what the number is (fan / power), so no unit is needed.
                let glyph = Self.glyph(for: c.secondaryKind)
                let glyphW: CGFloat = glyph == nil ? 0 : 8.5, glyphGap: CGFloat = glyph == nil ? 0 : 1.5
                let w1 = slotWidth(c.primaryKind, font: Fonts.top, withUnit: false, actual: top)
                let w2 = glyphW + glyphGap + slotWidth(c.secondaryKind, font: Fonts.bottom, withUnit: false, actual: c.secondaryText)
                width = max(w1, w2)
                // Both cap heights plus the gap form one block centred in the item; each line is centred horizontally.
                let gap: CGFloat = 2.5
                let block = Fonts.top.capHeight + gap + Fonts.bottom.capHeight
                let bottomBaseline = snap((Self.height - block) / 2)
                let topBaseline = snap(bottomBaseline + Fonts.bottom.capHeight + gap)
                put(a, Fonts.top, x: pad + snap((width - a.size().width) / 2), baseline: topBaseline)
                let lineW = glyphW + glyphGap + b.size().width
                let x2 = pad + snap((width - lineW) / 2)
                if let glyph {
                    let capH = Fonts.bottom.capHeight
                    ops.append { _ in Self.drawSymbol(glyph, size: 7.5, weight: .bold, color: base,
                                                      in: NSRect(x: x2, y: bottomBaseline, width: glyphW, height: capH)) }
                }
                put(b, Fonts.bottom, x: x2 + glyphW + glyphGap, baseline: bottomBaseline)
            }

        case .pill:
            // The value is knocked out of a filled rounded badge, like the input-source badge («РУ») beside it.
            let s = c.primaryText + stale
            let a = text(s, Fonts.pill, .black)
            let w = slotWidth(c.primaryKind, font: Fonts.pill, withUnit: false, actual: s)
            let padX: CGFloat = 5, h: CGFloat = 17
            width = w + 2 * padX
            let baseline = centredBaseline(Fonts.pill), descender = Fonts.pill.descender
            ops.append { _ in
                let r = NSRect(x: pad, y: snap((Self.height - h) / 2), width: w + 2 * padX, height: h)
                accent.setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                a.draw(at: NSPoint(x: r.minX + padX + snap((w - a.size().width) / 2), y: baseline + descender))
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }

        case .ringTemp:
            let d: CGFloat = 15
            valueAfter(accessory: d, gap: 4) { _ in
                ring(in: NSRect(x: pad + 1, y: snap((Self.height - d) / 2) + 1, width: d - 2, height: d - 2), lineWidth: 2)
            }

        case .bar:
            // A vertical level like a tiny battery: filled from the bottom by the value's place on its scale.
            let bw: CGFloat = 6, bh: CGFloat = 16
            valueAfter(accessory: bw, gap: 4) { _ in
                let r = NSRect(x: pad + 0.5, y: snap((Self.height - bh) / 2) + 0.5, width: bw - 1, height: bh - 1)
                let outline = NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2)
                outline.lineWidth = 1.1
                accent.withAlphaComponent(0.55).setStroke()
                outline.stroke()
                let inner = r.insetBy(dx: 1.5, dy: 1.5)
                let fill = NSRect(x: inner.minX, y: inner.minY, width: inner.width,
                                  height: max(inner.height * max(fraction, 0.1), inner.width))
                accent.setFill()
                NSBezierPath(roundedRect: fill, xRadius: inner.width / 2, yRadius: inner.width / 2).fill()
            }

        case .sparkline:
            // The last 5 minutes as a line with a faint area under it; a flat dim line until two samples exist.
            let gw: CGFloat = 26, gh: CGFloat = 13
            let points = c.spark
            valueAfter(accessory: gw, gap: 4) { _ in
                let r = NSRect(x: pad, y: snap((Self.height - gh) / 2), width: gw, height: gh)
                guard points.count >= 2 else {
                    let flat = NSBezierPath()
                    flat.move(to: NSPoint(x: r.minX, y: r.midY)); flat.line(to: NSPoint(x: r.maxX, y: r.midY))
                    flat.lineWidth = 1.5
                    accent.withAlphaComponent(0.35).setStroke()
                    flat.stroke()
                    return
                }
                let step = r.width / CGFloat(points.count - 1)
                let line = NSBezierPath()
                for (i, p) in points.enumerated() {
                    let pt = NSPoint(x: r.minX + CGFloat(i) * step, y: r.minY + 1 + CGFloat(p) * (r.height - 2))
                    if i == 0 { line.move(to: pt) } else { line.line(to: pt) }
                }
                if let area = line.copy() as? NSBezierPath {
                    area.line(to: NSPoint(x: r.maxX, y: r.minY)); area.line(to: NSPoint(x: r.minX, y: r.minY)); area.close()
                    accent.withAlphaComponent(0.22).setFill()
                    area.fill()
                }
                line.lineWidth = 1.5
                line.lineJoinStyle = .round
                line.lineCapStyle = .round
                accent.setStroke()
                line.stroke()
            }

        case .iconTempFan, .chipTempFan, .flameTempFan, .stackedIcons, .stackedUnits, .tempRPM, .compact, .badgeFan, .ringFan,
             .cpuGpu, .cpuGpuStacked, .fanOnly, .custom:
            guard let L = c.composedLayout, !c.composed.isEmpty else { valueAfter(accessory: 0, gap: 0); break }
            composeLabel(L, c.composed)

        case .gauge:
            let d: CGFloat = 20
            let font = c.primaryText.count > 2 ? Fonts.gaugeSmall : Fonts.gauge
            let a = text(c.primaryText, font, base)
            width = d + (stale.isEmpty ? 0 : 4)
            ops.append { _ in
                ring(in: NSRect(x: pad + 1, y: snap((Self.height - d) / 2) + 1, width: d - 2, height: d - 2), lineWidth: 2.2)
            }
            put(a, font, x: pad + snap((d - a.size().width) / 2), baseline: centredBaseline(font))
            if !stale.isEmpty {
                put(text(stale, Fonts.single, base), Fonts.single, x: pad + d, baseline: centredBaseline(Fonts.single))
            }
        }

        if c.badge != .none {
            let x = pad + width + 1
            let (glyph, color): (String, NSColor) = c.badge == .safety
                ? ("exclamationmark.circle.fill", ramp.nsInk(1, dark: c.dark))
                : ("diamond.fill", Self.resolved(.controlAccentColor, dark: c.dark))
            let size: CGFloat = c.badge == .safety ? 7 : 6
            ops.append { _ in Self.drawSymbol(glyph, size: size, weight: .bold, color: color,
                                              in: NSRect(x: x, y: Self.height - 9, width: 6, height: 7)) }
            width += badgeWidth
        }

        let size = NSSize(width: ceil(width + 2 * pad), height: Self.height)
        let img = NSImage(size: size)
        for scale in scales {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                                             pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            // The point size must be set BEFORE the context is made: the context takes its user space from it. Set
            // afterwards, a 2× rep was drawn in pixel units — the label came out half-size in the bottom-left corner.
            rep.size = size
            guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            let rect = NSRect(origin: .zero, size: size)
            if let appearance { appearance.performAsCurrentDrawingAppearance { ops.forEach { $0(rect) } } }
            else { ops.forEach { $0(rect) } }
            ctx.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            img.addRepresentation(rep)
        }
        img.isTemplate = c.template
        return img
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
