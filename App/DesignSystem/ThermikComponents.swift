//  ThermikComponents.swift — reusable SwiftUI components (MIT). OWNER: Unit 7. Public API frozen for Unit 8
//  (additions allowed). Liquid Glass only on the control layer (SPEC §4.3); every coloured value also has text and a glyph.
import SwiftUI
import ThermikCore

// MARK: - Surfaces

/// Content surface (cards in the popover / main window). NOT glass: Liquid Glass is reserved for the
/// control layer (toolbars, mode switchers, floating buttons) per Apple HIG.
/// Radius 14 everywhere: inside the 18-pt popover a `ConcentricRectangle` with a 14-pt minimum resolves to 14 anyway.
struct ThermikCard: ViewModifier {
    var radius: CGFloat = ThermikMetrics.cardRadius
    var padding: CGFloat = ThermikMetrics.gutter
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.separator.opacity(contrast == .increased ? 1 : 0.5), lineWidth: contrast == .increased ? 1 : 0.5))
    }
}

/// Control surface: Liquid Glass on macOS 26+, material on 14/15, opaque with Reduce Transparency (SPEC §4.3.4).
struct ThermikGlass<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color? = nil
    var interactive: Bool = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .background(tint.map { AnyShapeStyle($0.opacity(0.22)) } ?? AnyShapeStyle(.clear), in: shape)
                .overlay(shape.stroke(.separator, lineWidth: contrast == .increased ? 1 : 0.5))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .background(tint.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(.clear), in: shape)
                .overlay(shape.stroke(.white.opacity(contrast == .increased ? 0.35 : 0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }
    @available(macOS 26.0, *)
    private var glass: Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint.opacity(0.35)) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    func thermikCard(radius: CGFloat = ThermikMetrics.cardRadius, padding: CGFloat = ThermikMetrics.gutter) -> some View {
        modifier(ThermikCard(radius: radius, padding: padding))
    }
    func thermikGlass<S: Shape>(_ shape: S = Capsule(), tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(ThermikGlass(shape: shape, tint: tint, interactive: interactive))
    }
}

/// Groups glass children so they morph/blend together on macOS 26; transparent passthrough before
/// (and with Reduce Transparency, where the children are opaque).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) { self.spacing = spacing; self.content = content() }
    var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Temperature text & badges

/// New readings replace the digits without animation: a rolling-digit transition on every tick kept the panel and the
/// main window redrawing at the display rate (most of their CPU time).
struct TemperatureText: View {
    var celsius: Double
    var scale: ThermalScale = .soc
    var font: Font = ThermikFont.value
    var unit: UnitTemperature = .celsius
    var colored: Bool = true
    /// Stale / gated values are shown dimmed (SPEC §4.14).
    var dimmed: Bool = false
    @Environment(\.thermikRamp) private var ramp

    init(celsius: Double, scale: ThermalScale = .soc, font: Font = ThermikFont.value, unit: UnitTemperature = .celsius,
         colored: Bool = true, dimmed: Bool = false) {
        self.celsius = celsius; self.scale = scale; self.font = font; self.unit = unit; self.colored = colored; self.dimmed = dimmed
    }

    var body: some View {
        Text(ThermikFormat.temp(celsius, unit: unit))
            .font(font)
            .foregroundStyle(dimmed ? AnyShapeStyle(.secondary)
                             : colored ? AnyShapeStyle(ramp.ink(scale.normalized(celsius))) : AnyShapeStyle(.primary))
            .accessibilityLabel(Text(Self.spoken(celsius, scale: scale, unit: unit)))
    }

    /// VoiceOver form "70 degrees, Hot" / «70 градусов, Горячо» (SPEC §4.13; default CPU/GPU scale).
    static func spoken(_ celsius: Double, scale: ThermalScale, unit: UnitTemperature = .celsius) -> String {
        let n = ThermikFormat.degrees(celsius, unit: unit)
        return String(localized: "\(n) degrees") + ", " + scale.level(celsius, unit: unit).localizedTitle
    }
}

struct LevelBadge: View {
    var level: ThermalLevel
    var compact = false
    @Environment(\.thermikRamp) private var ramp
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let t = level.stopT
        Label { if !compact { Text(level.title) } } icon: { Image(systemName: level.symbol) }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ramp.ink(t))
            .padding(.horizontal, compact ? 5 : 8).padding(.vertical, 3)
            .background(ramp.vivid(t).opacity(contrast == .increased ? 0.28 : 0.16), in: Capsule())
            .overlay { if contrast == .increased { Capsule().strokeBorder(ramp.ink(t), lineWidth: 1) } }
            .accessibilityLabel(Text(level.title))
    }
}

/// Thermal pressure (ProcessInfo.thermalState or the macOS pressure level) as a chip. Titles follow the glossary
/// (Nominal / Moderate / Heavy / Throttling, SPEC §4.12).
enum PressureLevel: Int, Sendable { case nominal, fair, serious, critical
    init(_ s: ProcessInfo.ThermalState) {
        switch s { case .nominal: self = .nominal; case .fair: self = .fair; case .serious: self = .serious; case .critical: self = .critical; @unknown default: self = .nominal }
    }
    var title: LocalizedStringKey { switch self { case .nominal: "Nominal"; case .fair: "Moderate"; case .serious: "Heavy"; case .critical: "Throttling" } }
    init(_ p: ThermalPressure) {
        switch p { case .nominal: self = .nominal; case .moderate: self = .fair; case .heavy: self = .serious; case .trapping, .sleeping: self = .critical }
    }
    var energy: Double { Double(rawValue) / 3 }
    var symbol: String {
        switch self { case .nominal: "gauge.with.dots.needle.0percent"; case .fair: "gauge.with.dots.needle.33percent"
        case .serious: "gauge.with.dots.needle.67percent"; case .critical: "gauge.with.dots.needle.100percent" }
    }
    /// Ramp position used for the chip ink/tint (DES §7.3.3: warm / hot / critical inks). A colour only, not a level.
    var t: Double { [0.35, 0.62, 0.8, 1.0][rawValue] }
}

struct PressureChip: View {
    var level: PressureLevel
    /// Overrides the level title (e.g. the exact macOS level "Critical" for ThermalPressure.sleeping).
    var title: String? = nil
    @Environment(\.thermikRamp) private var ramp
    var body: some View {
        let t = level.t
        Label { if let title { Text(title) } else { Text(level.title) } } icon: { Image(systemName: level.symbol) }
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(level == .nominal ? AnyShapeStyle(.secondary) : AnyShapeStyle(ramp.ink(t)))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .thermikGlass(Capsule(), tint: level == .nominal ? nil : ramp.vivid(t))
            .help(Text("macOS thermal pressure"))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Thermal pressure"))
            .accessibilityValue(title.map { Text($0) } ?? Text(level.title))
    }
}

extension PressureChip {
    /// Chip for the macOS thermal pressure level (LevelChip's fallback before the first reading).
    init(pressure: ThermalPressure) { self.init(level: PressureLevel(pressure), title: pressure.title) }
}

/// The hottest sensor's level on its own colour scale (Settings › Appearance) as a glass chip, PressureChip's look with
/// the level's ink and tint. The popover header shows it instead of the macOS pressure, which stays "Nominal" long
/// after a die passes the user's "Critical" stop (macOS raises it only once it has to throttle); the tooltip and the
/// VoiceOver value still name the macOS pressure. A plain button: `action` opens Overview. Before the first reading
/// (`level == nil`) it shows the macOS PressureChip instead, still clickable. `dimmed`: stale readings (SPEC §4.14),
/// secondary text without a tint, like the dimmed hero value.
struct LevelChip: View {
    var level: ThermalLevel?
    var pressure: ThermalPressure
    var dimmed = false
    var action: () -> Void
    @Environment(\.thermikRamp) private var ramp

    init(level: ThermalLevel?, pressure: ThermalPressure, dimmed: Bool = false, action: @escaping () -> Void) {
        self.level = level; self.pressure = pressure; self.dimmed = dimmed; self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let level {
                let t = level.stopT
                Label { Text(level.title) } icon: { Image(systemName: level.symbol) }
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(ramp.ink(t)))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    // Not interactive glass: the click closes the panel and drops its content tree mid press-animation,
                    // and the first build that had it crashed in a SwiftUI layout pass right after that click.
                    .thermikGlass(Capsule(), tint: dimmed ? nil : ramp.vivid(t))
                    .help(Text(verbatim: Self.explanation(pressure) + "\n" + String(localized: "Click to open Overview.")))
            } else {
                PressureChip(pressure: pressure)       // keeps its own "macOS thermal pressure" tooltip
            }
        }
        .buttonStyle(.plain)
        .fixedSize()                                    // the caption beside it truncates, never the chip
        .accessibilityLabel(level == nil ? Text("Thermal pressure") : Text("Thermal state"))
        .accessibilityValue(Text(verbatim: level.map { $0.localizedTitle + ", " + Self.pressureLine(pressure) } ?? pressure.title))
        .accessibilityHint(Text("Opens Overview"))
    }

    /// "macOS thermal pressure: Nominal" (tooltips, VoiceOver).
    static func pressureLine(_ pressure: ThermalPressure) -> String {
        String(localized: "macOS thermal pressure: \(pressure.title)")
    }

    /// What the level stands for, next to the macOS pressure (this chip's and Overview's "Thermal pressure" tooltips).
    static func explanation(_ pressure: ThermalPressure) -> String {
        String(localized: "Level of the hottest sensor on its colour scale.") + "\n" + pressureLine(pressure)
    }
}

/// Small capsule chip ("Paused", "Max · returns to Auto in 28:41"). Not glass: it sits inside content.
struct InfoChip<Content: View>: View {
    var tint: Color = .secondary
    @ViewBuilder var label: Content
    init(tint: Color = .secondary, @ViewBuilder label: () -> Content) { self.tint = tint; self.label = label() }
    var body: some View {
        label
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// One-line state message with a glyph and an optional trailing action (fan states, helper lines, banners).
struct StatusLine<Accessory: View>: View {
    var symbol: String
    var text: String
    var tint: Color = .secondary
    @ViewBuilder var accessory: Accessory
    init(symbol: String, text: String, tint: Color = .secondary, @ViewBuilder accessory: () -> Accessory) {
        self.symbol = symbol; self.text = text; self.tint = tint; self.accessory = accessory()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            accessory
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .contain)
    }
}

extension StatusLine where Accessory == EmptyView {
    init(symbol: String, text: String, tint: Color = .secondary) {
        self.init(symbol: symbol, text: text, tint: tint) { EmptyView() }
    }
}

// MARK: - Fan glyph with speed-proportional spin

/// Stylised spin: real blades at 6000 rpm would alias, so map rpm → 0.25…2 rev/s.
/// Continuous spin is done by Core Animation (CASpinningSymbol, ≈0 % app CPU) instead of TimelineView (5–9 %).
/// Static `fan.fill` with Reduce Motion, Low Power Mode, "Animated effects" off or while the host is hidden.
struct FanGlyph: View {
    var rpm: Double
    var maxRPM: Double
    var size: CGFloat = 22
    var tint: Color = .accentColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.thermikAnimatedEffects) private var userEnabled
    @Environment(\.thermikEffectsVisible) private var visible

    init(rpm: Double, maxRPM: Double, size: CGFloat = 22, tint: Color = .accentColor) {
        self.rpm = rpm; self.maxRPM = maxRPM; self.size = size; self.tint = tint
    }

    static func revPerSec(rpm: Double, maxRPM: Double) -> Double {
        guard rpm > 50, maxRPM > 0 else { return 0 }
        return 0.25 + 1.75 * min(max(rpm / maxRPM, 0), 1)
    }

    var body: some View {
        let running = rpm > 50
        let spin = EffectsPolicy(reduceMotion: reduceMotion, userEnabled: userEnabled, visible: visible).animate
        Group {
            if running && spin {
                CASpinningSymbol(symbol: "fan.fill", pointSize: size, revPerSec: Self.revPerSec(rpm: rpm, maxRPM: maxRPM),
                                 color: NSColor(tint))
            } else {
                Image(systemName: running ? "fan.fill" : "fan")
                    .font(.system(size: size, weight: .regular))
                    .foregroundStyle(running ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
            }
        }
        .frame(width: size * 1.25, height: size * 1.25)
        .accessibilityLabel(running ? Text("Fan running") : Text("Fan stopped"))
    }
}

// MARK: - Sparkline (two Shapes — cheaper than a Chart per row)

/// Drawn with Shapes, not a Canvas: on macOS 26+ every Canvas got its own RenderBox GPU surfaces, 2–3 MB per
/// sparkline (≈ 130 MB with the panel's groups expanded).
struct Sparkline: View {
    var values: [Float]              // already downsampled to ≤ 2×width points
    var scale: ThermalScale = .soc
    var domain: ClosedRange<Double>? // °C; nil = auto from data with 4 °C padding
    var lineWidth: CGFloat = 1.5
    var fill = true
    @Environment(\.thermikRamp) private var ramp

    init(values: [Float], scale: ThermalScale = .soc, domain: ClosedRange<Double>? = nil, lineWidth: CGFloat = 1.5,
         fill: Bool = true) {
        self.values = values; self.scale = scale; self.domain = domain; self.lineWidth = lineWidth; self.fill = fill
    }

    var body: some View {
        let values = self.values.filter(\.isFinite)
        let lo = domain?.lowerBound ?? Double(values.min() ?? 0) - 4
        let hi = domain?.upperBound ?? Double(values.max() ?? 0) + 4
        let span = max(hi - lo, 1)
        let stops = stride(from: 0.0, through: 1.0, by: 0.25).map { f -> Gradient.Stop in
            .init(color: ramp.vivid(scale.normalized(hi - f * span)), location: f)
        }
        let areaTop = ramp.vivid(scale.normalized(Double(values.last ?? 0))).opacity(0.28)
        ZStack {
            if fill {
                SparklinePath(values: values, lo: lo, span: span, closed: true)
                    .fill(LinearGradient(colors: [areaTop, .clear], startPoint: .top, endPoint: .bottom))
            }
            // Vertical gradient = the thermal ramp across the visible °C domain → line colour encodes value.
            SparklinePath(values: values, lo: lo, span: span, closed: false)
                .stroke(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// The sparkline polyline across the full rect (`closed`: down to the bottom edge, for the area fill).
private struct SparklinePath: Shape {
    var values: [Float]
    var lo: Double
    var span: Double
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let dx = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let p = CGPoint(x: rect.minX + CGFloat(i) * dx, y: rect.minY + rect.height * (1 - CGFloat((Double(v) - lo) / span)))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Sensor rows & groups (value-based; the popover uses live rows that observe LiveSensor directly)

/// Group header content (symbol, title, count, hottest sparkline + value, chevron). Shared by the kit section and the
/// popover's live section so both look identical.
struct SensorGroupHeaderLabel: View {
    var symbol: String
    var title: String
    var count: Int
    var history: [Float]?
    var celsius: Double?
    var scale: ThermalScale = .soc
    var unit: UnitTemperature = .celsius
    var expanded: Bool
    var showsSparkline = true
    var dimmed = false
    var height: CGFloat = ThermikMetrics.groupHeaderHeight

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            Text(count.formatted(.number.grouping(.never))).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Spacer(minLength: 6)
            if showsSparkline, let history {
                Sparkline(values: history, scale: scale)
                    .frame(width: ThermikMetrics.sparklineWidth, height: ThermikMetrics.sparklineHeight)
            }
            Group {
                if let celsius {
                    TemperatureText(celsius: celsius, scale: scale, font: ThermikFont.valueSmall, unit: unit, dimmed: dimmed)
                } else {
                    Text(verbatim: "—").font(ThermikFont.valueSmall).foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 40, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .frame(height: height).contentShape(Rectangle())
    }
}

// MARK: - Fan modes & card

/// Segmented mode switcher: morphing glass selection on macOS 26, native segmented Picker before
/// (and with Reduce Transparency). `busy` shows a spinner in that pill ("Taking control…", SPEC §4.14).
/// Labels are never cut: the glass pills share the width equally while the longest label fits that way, otherwise each
/// pill gets its label's width plus an equal share of the rest (ModePillsLayout). Russian needs ≈ 294 pt at 11 pt
/// («Авто · Кривая · Фиксированная · Максимум», measured with AppKit), so it fits the popover's 316 pt row on its own.
/// Where the full labels do not fit, the modes that are not selected collapse to their symbols (the title stays the
/// tooltip and the VoiceOver label).
struct ModeSwitcher: View {
    @Binding var mode: FanMode
    var compact = false
    var busy: FanMode? = nil
    @Namespace private var ns
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    init(mode: Binding<FanMode>, compact: Bool = false, busy: FanMode? = nil) {
        self._mode = mode; self.compact = compact; self.busy = busy
    }

    var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            ViewThatFits(in: .horizontal) {
                glassPills(symbolsForOthers: false)
                glassPills(symbolsForOthers: true)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Fan mode"))
        } else {
            HStack(spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    FittedSegmentedControl(mode: $mode, symbolsForOthers: false)
                    FittedSegmentedControl(mode: $mode, symbolsForOthers: true)
                }
                if busy != nil { ProgressView().controlSize(.small) }
            }
        }
    }

    @available(macOS 26.0, *)
    private func glassPills(symbolsForOthers: Bool) -> some View {
        GlassEffectContainer(spacing: 4) {
            ModePillsLayout(spacing: 2) {
                ForEach(FanMode.allCases) { m in
                    let symbolOnly = symbolsForOthers && m != mode
                    Button { withAnimation(ThermikMotion.unlessReduced(ThermikMotion.modeMorph, reduceMotion)) { mode = m } } label: {
                        HStack(spacing: 4) {
                            if busy == m { ProgressView().controlSize(.mini) }
                            if symbolOnly {
                                Image(systemName: m.symbol)
                            } else {
                                // The semibold (selected) width is reserved, so selecting a pill never re-flows the row.
                                Text(m.title).fontWeight(.semibold).hidden()
                                    .overlay { Text(m.title).fontWeight(mode == m ? .semibold : .regular) }
                            }
                        }
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .font(.system(size: 11))
                        .padding(.horizontal, compact ? 8 : 10).padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background {
                        if mode == m {
                            Capsule().fill(.clear)
                                .glassEffect(.regular.tint(.accentColor.opacity(0.35)).interactive(), in: Capsule())
                                .glassEffectID("sel", in: ns)
                        }
                    }
                    .help(symbolOnly ? Text(m.title) : Text(verbatim: ""))
                    .accessibilityLabel(Text(m.title))
                    .accessibilityAddTraits(mode == m ? .isSelected : [])
                }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
        }
    }
}

/// Native segmented control with content-fitted segments (`.fit`). SwiftUI's segmented Picker sizes every segment like
/// the widest one: the Russian labels then need 426 pt instead of 290 pt (measured, small control size), so the 316 pt
/// popover row cut «Фиксированная». The control keeps its fitting width; `symbolsForOthers` shows symbols for the
/// modes that are not selected (title as tooltip and accessibility description).
private struct FittedSegmentedControl: NSViewRepresentable {
    @Binding var mode: FanMode
    var symbolsForOthers: Bool

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl()
        c.segmentCount = FanMode.allCases.count
        c.trackingMode = .selectOne
        c.segmentDistribution = .fit
        c.controlSize = .small
        c.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        c.target = context.coordinator
        c.action = #selector(Coordinator.changed(_:))
        c.setAccessibilityLabel(String(localized: "Fan mode"))
        return c
    }

    func updateNSView(_ c: NSSegmentedControl, context: Context) {
        context.coordinator.mode = $mode
        for (i, m) in FanMode.allCases.enumerated() {
            if symbolsForOthers && m != mode {
                c.setLabel("", forSegment: i)
                c.setImage(NSImage(systemSymbolName: m.symbol, accessibilityDescription: m.title), forSegment: i)
                c.setToolTip(m.title, forSegment: i)
            } else {
                c.setImage(nil, forSegment: i)
                c.setLabel(m.title, forSegment: i)
                c.setToolTip(nil, forSegment: i)
            }
        }
        c.selectedSegment = FanMode.allCases.firstIndex(of: mode) ?? -1
        c.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    func makeCoordinator() -> Coordinator { Coordinator(mode: $mode) }

    @MainActor final class Coordinator: NSObject {
        var mode: Binding<FanMode>
        init(mode: Binding<FanMode>) { self.mode = mode }
        @objc func changed(_ sender: NSSegmentedControl) {
            let all = FanMode.allCases
            guard all.indices.contains(sender.selectedSegment) else { return }
            mode.wrappedValue = all[sender.selectedSegment]
        }
    }
}

/// Pill widths of the mode switcher: equal while the widest pill fits that way (a segmented-control look), otherwise
/// every pill gets its ideal width plus an equal share of the leftover. Below the pills' total ideal width they shrink
/// proportionally (and the labels' minimumScaleFactor takes over). Reports its ideal width for an unspecified
/// proposal, so ViewThatFits can tell whether the labels fit.
private struct ModePillsLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(subviews.count - 1, 0))
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let n = CGFloat(subviews.count)
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let available = max(bounds.width - spacing * (n - 1), 0)
        let total = ideal.reduce(0, +)
        let widths: [CGFloat]
        if (ideal.max() ?? 0) * n <= available {
            widths = Array(repeating: available / n, count: subviews.count)
        } else if total <= available {
            widths = ideal.map { $0 + (available - total) / n }
        } else {
            widths = ideal.map { total > 0 ? $0 * available / total : 0 }
        }
        var x = bounds.minX
        for (i, s) in subviews.enumerated() {
            s.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                    proposal: ProposedViewSize(width: widths[i], height: bounds.height))
            x += widths[i] + spacing
        }
    }
}

struct FanRowItem: Identifiable, Sendable, Hashable {
    let id: Int
    var name: String          // "Left fan", "Right fan"
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
    var targetRPM: Double?
    var mode: FanMode
}

/// Moves once per reading, without animation: rpm changes on nearly every tick, and a spring per tick never settled.
struct RPMBar: View {
    var rpm, minRPM, maxRPM: Double
    var target: Double?

    init(rpm: Double, minRPM: Double, maxRPM: Double, target: Double? = nil) {
        self.rpm = rpm; self.minRPM = minRPM; self.maxRPM = maxRPM; self.target = target
    }

    var body: some View {
        GeometryReader { g in
            let f = { (v: Double) in CGFloat(min(max(v / max(maxRPM, 1), 0), 1)) * g.size.width }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(LinearGradient(colors: [.accentColor.opacity(0.6), .accentColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(f(rpm), g.size.height))
                    .opacity(rpm > 50 ? 1 : 0)
                Rectangle().fill(.secondary).frame(width: 1, height: g.size.height + 4).offset(x: f(minRPM))
                if let target { Circle().fill(.primary).frame(width: 6, height: 6).offset(x: f(target) - 3) }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Fans panel (popover): one full-width row per fan + ONE shared mode switcher.
// Two side-by-side FanCards do not fit a 360-pt popover once the 4-segment switcher is inside (verified by render).

struct FanRow: View {
    var fan: FanRowItem
    var body: some View {
        HStack(spacing: 10) {
            FanGlyph(rpm: fan.rpm, maxRPM: fan.maxRPM, size: 17)
            Text(fan.name).font(ThermikFont.body).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            RPMBar(rpm: fan.rpm, minRPM: fan.minRPM, maxRPM: fan.maxRPM, target: fan.targetRPM)
                .frame(width: 84, height: 5)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(fan.rpm < 50 ? String(localized: "Off") : ThermikFormat.rpm(fan.rpm))
                    .font(ThermikFont.valueSmall)
                    .contentTransition(.numericText(value: fan.rpm))
                if fan.rpm >= 50 { Text("rpm").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
            .frame(minWidth: 62, alignment: .trailing)
        }
        .frame(height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(fan.name))
        .accessibilityValue(Text(fan.rpm < 50 ? String(localized: "Off") : ThermikFormat.rpmWithUnit(fan.rpm)))
    }
}

// MARK: - Render-server fan spin (cheapest): CABasicAnimation runs in the WindowServer, not in our process.
// Measured (2 glyphs, live window): TimelineView 60 fps 5–9 % CPU, .symbolEffect(.rotate) 4.9 %, repeatForever 3.7 %,
// this CALayer version ≈ idle. Use it wherever a fan glyph spins continuously.
struct CASpinningSymbol: NSViewRepresentable {
    var symbol: String
    var pointSize: CGFloat
    var revPerSec: Double                // 0 = stopped
    var color: NSColor = .controlAccentColor

    final class SpinView: NSView {
        let spin = CALayer()
        fileprivate var config: (symbol: String, pointSize: CGFloat, color: NSColor)?
        private var appliedSpeed: Double = -1
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(spin)
            spin.contentsGravity = .center
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { false }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            spin.bounds = bounds; spin.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            renderContents()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            renderContents()                 // dynamic colours (accent) resolve per appearance
        }

        /// Rasterises the symbol for the current scale and appearance (a CALayer does not re-resolve NSImage colours).
        func renderContents() {
            guard let config else { return }
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            spin.contentsScale = scale
            let cfg = NSImage.SymbolConfiguration(pointSize: config.pointSize, weight: .regular)
                .applying(.init(paletteColors: [config.color]))
            guard let img = NSImage(systemSymbolName: config.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            else { spin.contents = nil; return }
            var cg: CGImage?
            effectiveAppearance.performAsCurrentDrawingAppearance {
                var rect = NSRect(origin: .zero, size: img.size)
                cg = img.cgImage(forProposedRect: &rect, context: nil,
                                 hints: [.ctm: AffineTransform(scale: scale)])
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            spin.contents = cg
            CATransaction.commit()
        }

        func apply(revPerSec: Double) {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let speed = reduceMotion ? 0 : max(revPerSec, 0)
            guard speed != appliedSpeed else { return }
            appliedSpeed = speed
            if speed <= 0 {
                spin.removeAnimation(forKey: "spin")
                spin.speed = 1; spin.timeOffset = 0; spin.beginTime = 0
                return
            }
            if spin.animation(forKey: "spin") == nil {
                let a = CABasicAnimation(keyPath: "transform.rotation.z")
                a.fromValue = 0; a.toValue = -2 * Double.pi            // clockwise in a non-flipped layer
                a.duration = 1; a.repeatCount = .infinity
                a.isRemovedOnCompletion = false
                spin.add(a, forKey: "spin")
            }
            // Change speed without restarting (keeps phase continuous): re-base timeOffset/beginTime.
            let now = CACurrentMediaTime()
            spin.timeOffset = spin.convertTime(now, from: nil)
            spin.beginTime = now
            spin.speed = Float(speed)
        }
    }

    func makeNSView(context: Context) -> SpinView { SpinView(frame: .zero) }

    func updateNSView(_ v: SpinView, context: Context) {
        let changed = v.config.map { $0.symbol != symbol || $0.pointSize != pointSize || !$0.color.isEqual(color) } ?? true
        if changed {
            v.config = (symbol, pointSize, color)
            v.renderContents()
        }
        v.apply(revPerSec: revPerSec)
    }

    static func dismantleNSView(_ v: SpinView, coordinator: ()) { v.spin.removeAllAnimations() }
}
