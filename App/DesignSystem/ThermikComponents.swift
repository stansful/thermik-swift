//  ThermikComponents.swift — reusable SwiftUI components (MIT).
import SwiftUI
import ThermikCore

// MARK: - Surfaces

/// Content surface (cards in the popover / main window). NOT glass: Liquid Glass is reserved for the
/// control layer (toolbars, mode switchers, floating buttons) per Apple HIG.
struct ThermikCard: ViewModifier {
    var radius: CGFloat = ThermikMetrics.cardRadius
    var padding: CGFloat = ThermikMetrics.gutter
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

/// Control surface: Liquid Glass on macOS 26+, material capsule on 14/15.
struct ThermikGlass<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color? = nil
    var interactive: Bool = false
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .background(tint.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(.clear), in: shape)
                .overlay(shape.stroke(.white.opacity(0.10), lineWidth: 0.5))
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

/// Groups glass children so they morph/blend together on macOS 26; transparent passthrough before.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Temperature text & badges

struct TemperatureText: View {
    var celsius: Double
    var scale: ThermalScale = .soc
    var font: Font = ThermikFont.value
    var unit: UnitTemperature = .celsius
    var colored: Bool = true
    var body: some View {
        Text(ThermikFormat.temp(celsius, unit: unit))
            .font(font)
            .foregroundStyle(colored ? AnyShapeStyle(ThermikPalette.ink(scale.normalized(celsius))) : AnyShapeStyle(.primary))
            .contentTransition(.numericText(value: celsius))
            .animation(.snappy(duration: 0.35), value: Int(celsius.rounded()))
            .accessibilityLabel(Text("\(Int(celsius.rounded())) degrees"))
    }
}

struct LevelBadge: View {
    var level: ThermalLevel
    var compact = false
    var body: some View {
        let t = ThermalScale.stopT[level.rawValue]
        Label { if !compact { Text(level.title) } } icon: { Image(systemName: level.symbol) }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ThermikPalette.ink(t))
            .padding(.horizontal, compact ? 5 : 8).padding(.vertical, 3)
            .background(ThermikPalette.vivid(t).opacity(0.16), in: Capsule())
            .accessibilityLabel(Text(level.title))
    }
}

/// Thermal pressure (ProcessInfo.thermalState + powermetrics-free heuristics) as a chip.
enum PressureLevel: Int, Sendable { case nominal, fair, serious, critical
    init(_ s: ProcessInfo.ThermalState) {
        switch s { case .nominal: self = .nominal; case .fair: self = .fair; case .serious: self = .serious; case .critical: self = .critical; @unknown default: self = .nominal }
    }
    var title: LocalizedStringKey { switch self { case .nominal: "Nominal"; case .fair: "Fair"; case .serious: "Serious"; case .critical: "Throttling" } }
    init(_ p: ThermalPressure) {
        switch p { case .nominal: self = .nominal; case .moderate: self = .fair; case .heavy: self = .serious; case .trapping, .sleeping: self = .critical }
    }
    var energy: Double { Double(rawValue) / 3 }
    var symbol: String {
        switch self { case .nominal: "gauge.with.dots.needle.0percent"; case .fair: "gauge.with.dots.needle.33percent"
        case .serious: "gauge.with.dots.needle.67percent"; case .critical: "gauge.with.dots.needle.100percent" }
    }
}

struct PressureChip: View {
    var level: PressureLevel
    var body: some View {
        let t: Double = [0.35, 0.62, 0.8, 1.0][level.rawValue]
        Label(level.title, systemImage: level.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(level == .nominal ? AnyShapeStyle(.secondary) : AnyShapeStyle(ThermikPalette.ink(t)))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .thermikGlass(Capsule(), tint: level == .nominal ? nil : ThermikPalette.vivid(t))
            .help("macOS thermal pressure")
    }
}

// MARK: - Fan glyph with speed-proportional spin

/// Stylised spin: real blades at 6000 rpm would alias, so map rpm → 0.25…2 rev/s.
/// Continuous spin is done by Core Animation (CASpinningSymbol, ≈0 % app CPU) instead of TimelineView (5–9 %).
struct FanGlyph: View {
    var rpm: Double
    var maxRPM: Double
    var size: CGFloat = 22
    var tint: Color = .accentColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func revPerSec(rpm: Double, maxRPM: Double) -> Double {
        guard rpm > 50, maxRPM > 0 else { return 0 }
        return 0.25 + 1.75 * min(max(rpm / maxRPM, 0), 1)
    }

    var body: some View {
        let running = rpm > 50
        Group {
            if running && !reduceMotion {
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

// MARK: - Sparkline (Canvas — cheaper than a Chart per row)

struct Sparkline: View {
    var values: [Float]              // already downsampled to ≤ 2×width points
    var scale: ThermalScale = .soc
    var domain: ClosedRange<Double>? // °C; nil = auto from data with 4 °C padding
    var lineWidth: CGFloat = 1.5
    var fill = true

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            guard values.count > 1 else { return }
            let lo = domain?.lowerBound ?? Double(values.min()!) - 4
            let hi = domain?.upperBound ?? Double(values.max()!) + 4
            let span = max(hi - lo, 1)
            let dx = size.width / CGFloat(values.count - 1)
            var path = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * dx, y: size.height * (1 - CGFloat((Double(v) - lo) / span)))
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            // Vertical gradient = the thermal ramp across the visible °C domain → line colour encodes value.
            let stops = stride(from: 0.0, through: 1.0, by: 0.25).map { f -> Gradient.Stop in
                let c = hi - f * span
                return .init(color: ThermikPalette.vivid(scale.normalized(c)), location: f)
            }
            let g = Gradient(stops: stops)
            if fill {
                var area = path
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [
                    ThermikPalette.vivid(scale.normalized(Double(values.last!))).opacity(0.28), .clear]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            ctx.stroke(path, with: .linearGradient(g, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Sensor rows & groups

struct SensorRowItem: Identifiable, Sendable, Hashable {
    let id: String
    var name: String
    var celsius: Double
    var history: [Float]
    var scale: ThermalScale = .soc
}

struct SensorRow: View {
    var reading: SensorRowItem
    var unit: UnitTemperature = .celsius
    var body: some View {
        HStack(spacing: 8) {
            Text(reading.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Sparkline(values: reading.history, scale: reading.scale, fill: false)
                .frame(width: 54, height: 14)
            TemperatureText(celsius: reading.celsius, scale: reading.scale, font: ThermikFont.valueSmall, unit: unit)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .frame(height: ThermikMetrics.rowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct SensorGroupItem: Identifiable, Sendable, Hashable {
    let id: String
    var title: String
    var symbol: String          // "cpu", "memorychip", "internaldrive", "battery.100percent", "wifi", "powerplug"…
    var readings: [SensorRowItem]
    var hottest: SensorRowItem? { readings.max { $0.celsius < $1.celsius } }
}

struct SensorGroupSection: View {
    var group: SensorGroupItem
    @Binding var expanded: Bool
    var unit: UnitTemperature = .celsius

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.28)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: group.symbol).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 18)
                    Text(group.title).font(.system(size: 12, weight: .semibold))
                    Text("\(group.readings.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    Spacer(minLength: 6)
                    if let h = group.hottest {
                        Sparkline(values: h.history, scale: h.scale).frame(width: 54, height: ThermikMetrics.sparklineHeight)
                        TemperatureText(celsius: h.celsius, scale: h.scale, font: ThermikFont.valueSmall, unit: unit)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))

            if expanded {
                VStack(spacing: 0) {
                    ForEach(group.readings) { r in SensorRow(reading: r, unit: unit).padding(.leading, 26) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Fan modes & card


/// Segmented mode switcher: morphing glass selection on macOS 26, native segmented Picker before.
struct ModeSwitcher: View {
    @Binding var mode: FanMode
    var compact = false
    @Namespace private var ns

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 2) {
                    ForEach(FanMode.allCases) { m in
                        Button { withAnimation(.bouncy(duration: 0.35)) { mode = m } } label: {
                            Label(m.title, systemImage: m.symbol)
                                .labelStyle(.titleOnly)
                                .font(.system(size: 11, weight: mode == m ? .semibold : .regular))
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
                        .accessibilityAddTraits(mode == m ? .isSelected : [])
                    }
                }
                .padding(3)
                .glassEffect(.regular, in: Capsule())
            }
        } else {
            Picker("Fan mode", selection: $mode) {
                ForEach(FanMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
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

struct FanCard: View {
    var fan: FanRowItem
    var onModeChange: @MainActor @Sendable (FanMode) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                FanGlyph(rpm: fan.rpm, maxRPM: fan.maxRPM, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(fan.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(fan.rpm < 50 ? String(localized: "Off") : ThermikFormat.rpm(fan.rpm))
                            .font(ThermikFont.value)
                            .contentTransition(.numericText(value: fan.rpm))
                        if fan.rpm >= 50 { Text("rpm").font(ThermikFont.unit).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                RPMBar(rpm: fan.rpm, minRPM: fan.minRPM, maxRPM: fan.maxRPM, target: fan.targetRPM)
                    .frame(width: 96, height: 6)
            }
            ModeSwitcher(mode: Binding(get: { fan.mode }, set: onModeChange), compact: true)
        }
        .thermikCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(fan.name))
    }
}

struct RPMBar: View {
    var rpm, minRPM, maxRPM: Double
    var target: Double?
    var body: some View {
        GeometryReader { g in
            let f = { (v: Double) in CGFloat(min(max((v - 0) / max(maxRPM, 1), 0), 1)) * g.size.width }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(LinearGradient(colors: [.accentColor.opacity(0.6), .accentColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(f(rpm), g.size.height))
                Rectangle().fill(.secondary).frame(width: 1, height: g.size.height + 4).offset(x: f(minRPM))
                if let target { Circle().fill(.primary).frame(width: 6, height: 6).offset(x: f(target) - 3) }
            }
            .animation(.smooth(duration: 0.8), value: rpm)
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
            Text(fan.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 6)
            RPMBar(rpm: fan.rpm, minRPM: fan.minRPM, maxRPM: fan.maxRPM, target: fan.targetRPM)
                .frame(width: 84, height: 5)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(fan.rpm < 50 ? String(localized: "Off") : ThermikFormat.rpm(fan.rpm))
                    .font(ThermikFont.valueSmall)
                    .contentTransition(.numericText(value: fan.rpm))
                Text("rpm").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(minWidth: 62, alignment: .trailing)
        }
        .frame(height: 28)
        .accessibilityElement(children: .combine)
    }
}

struct FansPanel: View {
    var fans: [FanRowItem]
    @Binding var mode: FanMode
    var onOpenCurve: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Fans", systemImage: "fan").font(.system(size: 12, weight: .semibold)).labelStyle(.titleAndIcon)
                Spacer()
                if mode == .curve {
                    Button("Edit curve…", action: onOpenCurve).buttonStyle(.link).font(.system(size: 11))
                }
            }
            ForEach(fans) { FanRow(fan: $0) }
            ModeSwitcher(mode: $mode, compact: true).padding(.top, 2)
        }
        .thermikCard()
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
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(spin)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            spin.bounds = bounds; spin.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
        override func viewDidChangeBackingProperties() { spin.contentsScale = window?.backingScaleFactor ?? 2 }
    }

    func makeNSView(context: Context) -> SpinView { SpinView(frame: .zero) }

    func updateNSView(_ v: SpinView, context: Context) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(paletteColors: [color]))
        v.spin.contents = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        v.spin.contentsGravity = .center
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if revPerSec <= 0 || reduceMotion {
            v.spin.removeAnimation(forKey: "spin"); return
        }
        if v.spin.animation(forKey: "spin") == nil {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi            // clockwise in a non-flipped layer
            a.duration = 1; a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            v.spin.add(a, forKey: "spin")
        }
        // Change speed without restarting (keeps phase continuous): re-base timeOffset/beginTime.
        let layer = v.spin
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.timeOffset = now
        layer.beginTime = CACurrentMediaTime()
        layer.speed = Float(revPerSec)
    }
}
