//  ThermikCharts.swift — live history chart and the chart kit for Thermik (MIT). OWNER: Unit 7 (kit; public API frozen
//  for Unit 8).
//  Charts rules (SPEC §4.11): explicit domains, no implicit animation on data ticks, hover in a sibling overlay,
//  monotone interpolation, at most one area, dashed thresholds, localized relative axis labels.
//  Drawn with Shapes and Text, not Swift Charts: any Swift Charts chart on screen made RenderBox hold 150–260 MB of
//  GPU surfaces on macOS 26+. `ChartFrame` lays out the plot, grid and axis labels as Swift Charts did, `ChartPath`
//  draws the marks.
import AppKit
import SwiftUI
import ThermikCore

// MARK: - Kit

/// Data domains mapped onto the plot rect (y grows upwards in data, downwards on screen).
struct ChartScale: Equatable {
    var plot: CGRect
    var x: ClosedRange<Double>
    var y: ClosedRange<Double>

    func px(_ v: Double) -> CGFloat { plot.minX + CGFloat((v - x.lowerBound) / Self.span(x)) * plot.width }
    func py(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - y.lowerBound) / Self.span(y)) * plot.height }
    /// The x value at `offset` points from the plot's leading edge.
    func xValue(atPlotOffset offset: CGFloat) -> Double { x.lowerBound + Double(offset / max(plot.width, 1)) * Self.span(x) }

    static func span(_ r: ClosedRange<Double>) -> Double { max(r.upperBound - r.lowerBound, .ulpOfOne) }

    /// The rect from a series' peak down to the baseline, in the plot's own coordinates: an area gradient anchored
    /// here (`.in(_:)`) runs over the area itself, as Swift Charts mapped an AreaMark's style, not over the whole plot.
    func areaRect(peak: Double, baseline: Double) -> CGRect {
        let top = py(max(peak, baseline)) - plot.minY, bottom = py(baseline) - plot.minY
        return CGRect(x: 0, y: top, width: plot.width, height: max(bottom - top, 1))
    }
}

/// A grid line and its axis label ("" draws the line only).
struct ChartTick: Hashable {
    var value: Double
    var label: String

    /// The multiples of `step` inside `domain` (Swift Charts' `.stride(by:)`).
    static func stride(_ domain: ClosedRange<Double>, by step: Double, label: (Double) -> String) -> [ChartTick] {
        guard step > 0 else { return [] }
        let first = (domain.lowerBound / step).rounded(.up) * step
        return Swift.stride(from: first, through: domain.upperBound + step * 1e-9, by: step)
            .map { ChartTick(value: $0, label: label($0)) }
    }

    /// About `count` round values (Swift Charts' `.automatic(desiredCount:)`): the step of 1, 2, 2.5 or 5 × 10ⁿ whose
    /// tick count is closest to `count`, the denser one on a tie — what Swift Charts chose for Thermik's domains
    /// (20…110 → 20s, 50…110 → 10s, 0…100 → 25s, 0…4 → 1s).
    static func automatic(_ domain: ClosedRange<Double>, count: Int, label: (Double) -> String) -> [ChartTick] {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0, span.isFinite, count > 0 else { return [] }
        let magnitude = pow(10, log10(span / Double(count)).rounded(.down))
        func ticks(_ step: Double) -> Int {
            Int(((domain.upperBound + step * 1e-9) / step).rounded(.down) - (domain.lowerBound / step).rounded(.up)) + 1
        }
        let steps = [0.1, 0.2, 0.25, 0.5, 1, 2, 2.5, 5, 10, 20, 25, 50].map { $0 * magnitude }
        let step = steps.min { a, b in
            let da = abs(ticks(a) - count), db = abs(ticks(b) - count)
            return da != db ? da < db : a < b
        } ?? magnitude
        return stride(domain, by: step, label: label)
    }
}

enum ChartInterpolation { case linear, monotone, stepEnd }

/// Marks in data units, drawn into the shape's rect (the plot): a line; with `baseline`, the area under it; with
/// `lower`, the band between `lower` and the line.
struct ChartPath: Shape {
    var x: [Double]
    var y: [Double]
    var xDomain: ClosedRange<Double>
    var yDomain: ClosedRange<Double>
    var interpolation: ChartInterpolation = .linear
    var baseline: Double? = nil
    var lower: [Double]? = nil

    init(x: [Double], y: [Double], xDomain: ClosedRange<Double>, yDomain: ClosedRange<Double>,
         interpolation: ChartInterpolation = .linear, baseline: Double? = nil, lower: [Double]? = nil) {
        self.x = x; self.y = y; self.xDomain = xDomain; self.yDomain = yDomain
        self.interpolation = interpolation; self.baseline = baseline; self.lower = lower
    }

    /// Time series (x = seconds since the reference date).
    init(_ samples: [Sample], xDomain: ClosedRange<Double>, yDomain: ClosedRange<Double>,
         interpolation: ChartInterpolation = .linear, baseline: Double? = nil) {
        self.init(x: samples.map { $0.time.timeIntervalSinceReferenceDate }, y: samples.map { Double($0.value) },
                  xDomain: xDomain, yDomain: yDomain, interpolation: interpolation, baseline: baseline)
    }

    /// A horizontal rule at `value` across the plot.
    static func rule(y value: Double, xDomain: ClosedRange<Double>, yDomain: ClosedRange<Double>) -> ChartPath {
        ChartPath(x: [xDomain.lowerBound, xDomain.upperBound], y: [value, value], xDomain: xDomain, yDomain: yDomain)
    }

    func path(in rect: CGRect) -> Path {
        let n = min(x.count, y.count)
        var path = Path()
        guard n > 0 else { return path }
        let sx = rect.width / CGFloat(ChartScale.span(xDomain)), sy = rect.height / CGFloat(ChartScale.span(yDomain))
        func point(_ i: Int, _ v: [Double]) -> CGPoint {
            CGPoint(x: rect.minX + CGFloat(x[i] - xDomain.lowerBound) * sx, y: rect.maxY - CGFloat(v[i] - yDomain.lowerBound) * sy)
        }
        let top = (0..<n).map { point($0, y) }
        path.move(to: top[0])
        Self.add(top, interpolation, to: &path)
        if let lower, lower.count >= n {
            let bottom = (0..<n).map { point($0, lower) }
            path.addLine(to: bottom[n - 1])
            if interpolation == .stepEnd {
                // Backwards, a step is riser first, then run: the same steps as the top edge.
                for i in stride(from: n - 1, through: 1, by: -1) {
                    path.addLine(to: CGPoint(x: bottom[i].x, y: bottom[i - 1].y))
                    path.addLine(to: bottom[i - 1])
                }
            } else {
                Self.add(bottom.reversed(), interpolation, to: &path)     // the same curve as forwards
            }
            path.closeSubpath()
        } else if let baseline {
            let base = rect.maxY - CGFloat(baseline - yDomain.lowerBound) * sy
            path.addLine(to: CGPoint(x: top[n - 1].x, y: base))
            path.addLine(to: CGPoint(x: top[0].x, y: base))
            path.closeSubpath()
        }
        return path
    }

    private static func add(_ p: [CGPoint], _ interpolation: ChartInterpolation, to path: inout Path) {
        guard p.count > 1 else { return }
        switch interpolation {
        case .linear:
            for q in p.dropFirst() { path.addLine(to: q) }
        case .stepEnd:
            for i in 1..<p.count {
                path.addLine(to: CGPoint(x: p[i].x, y: p[i - 1].y))
                path.addLine(to: p[i])
            }
        case .monotone:
            let m = tangents(p)
            for i in 0..<(p.count - 1) {
                let dx = (p[i + 1].x - p[i].x) / 3
                path.addCurve(to: p[i + 1], control1: CGPoint(x: p[i].x + dx, y: p[i].y + dx * m[i]),
                              control2: CGPoint(x: p[i + 1].x - dx, y: p[i + 1].y - dx * m[i + 1]))
            }
        }
    }

    /// Steffen's monotone tangents (d3 `curveMonotoneX`, Swift Charts' `.monotone`): smooth, never overshoots. The
    /// same curve comes out when the points are passed in reverse (the band's lower edge).
    private static func tangents(_ p: [CGPoint]) -> [CGFloat] {
        func slope(_ a: CGPoint, _ b: CGPoint) -> CGFloat { b.x != a.x ? (b.y - a.y) / (b.x - a.x) : 0 }
        func sign(_ v: CGFloat) -> CGFloat { v > 0 ? 1 : v < 0 ? -1 : 0 }
        let n = p.count
        guard n > 2 else { let s = slope(p[0], p[1]); return [s, s] }
        var m = [CGFloat](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            let h0 = p[i].x - p[i - 1].x, h1 = p[i + 1].x - p[i].x
            let s0 = slope(p[i - 1], p[i]), s1 = slope(p[i], p[i + 1])
            let q = h0 + h1 != 0 ? (s0 * h1 + s1 * h0) / (h0 + h1) : 0
            m[i] = (sign(s0) + sign(s1)) * min(abs(s0), abs(s1), 0.5 * abs(q))
        }
        m[0] = (3 * slope(p[0], p[1]) - m[1]) / 2
        m[n - 1] = (3 * slope(p[n - 2], p[n - 1]) - m[n - 2]) / 2
        return m
    }
}

/// Axis and annotation text (11 pt, as Swift Charts' axis labels): the size is measured so labels can be placed by
/// their edges.
struct ChartLabel: View {
    var text: String
    var size: CGFloat = 11
    var weight: Font.Weight = .regular

    init(_ text: String, size: CGFloat = 11, weight: Font.Weight = .regular) {
        self.text = text; self.size = size; self.weight = weight
    }

    var measured: CGSize {
        let w: NSFont.Weight = switch weight { case .medium: .medium; case .semibold: .semibold; case .bold: .bold; default: .regular }
        let s = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: w)])
        return CGSize(width: s.width.rounded(.up), height: s.height.rounded(.up))
    }

    var body: some View {
        Text(verbatim: text).font(.system(size: size, weight: weight)).lineLimit(1).fixedSize()
    }

    /// Places the label with the given anchor (a unit point of the label) at `point`.
    func placed(at point: CGPoint, anchor: UnitPoint) -> some View {
        let s = measured
        return position(x: point.x + (0.5 - anchor.x) * s.width, y: point.y + (0.5 - anchor.y) * s.height)
    }
}

/// The plot, its grid and axis labels, laid out as Swift Charts laid them out (measured against it): the plot fills the
/// frame but for the label gutters, y labels are centred on their grid lines even where they stick out of the frame,
/// x labels start just after theirs and are left out where they would run past the plot. `content` gets the plot
/// geometry and draws in the frame's coordinates; `.chartPlot(_:)` puts a view (the marks) on the plot rect.
struct ChartFrame<Content: View>: View {
    var x: ClosedRange<Double>
    var y: ClosedRange<Double>
    var xTicks: [ChartTick] = []
    var yTicks: [ChartTick] = []
    /// The y labels on the leading edge instead of the trailing one.
    var leadingYLabels = false
    /// A second set of labels for the same y ticks on the trailing edge (no grid lines of their own).
    var trailingYLabels: [ChartTick] = []
    @ViewBuilder var content: (ChartScale) -> Content

    private static var gap: CGFloat { 5 }

    var body: some View {
        GeometryReader { geo in
            let s = scale(in: geo.size)
            ZStack(alignment: .topLeading) {
                Path { p in
                    for t in xTicks { p.move(to: CGPoint(x: s.px(t.value), y: s.plot.minY)); p.addLine(to: CGPoint(x: s.px(t.value), y: s.plot.maxY)) }
                    for t in yTicks { p.move(to: CGPoint(x: s.plot.minX, y: s.py(t.value))); p.addLine(to: CGPoint(x: s.plot.maxX, y: s.py(t.value))) }
                }
                .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                .allowsHitTesting(false)
                content(s)
                labels(s).allowsHitTesting(false)          // a click on a label reaches the chart's input layer
            }
        }
    }

    @ViewBuilder private func labels(_ s: ChartScale) -> some View {
        let gap = Self.gap
        ForEach(visibleXTicks(s), id: \.self) { t in
            ChartLabel(t.label).placed(at: CGPoint(x: s.px(t.value) + 4, y: s.plot.maxY + 4), anchor: .topLeading)
                .foregroundStyle(.secondary)
        }
        ForEach(yTicks.filter { !$0.label.isEmpty }, id: \.self) { t in
            let label = ChartLabel(t.label)
            if leadingYLabels {
                label.placed(at: CGPoint(x: s.plot.minX - gap, y: s.py(t.value)), anchor: .trailing).foregroundStyle(.secondary)
            } else {
                label.placed(at: CGPoint(x: s.plot.maxX + gap, y: s.py(t.value)), anchor: .leading).foregroundStyle(.secondary)
            }
        }
        let secondX = s.plot.maxX + gap + (leadingYLabels ? 0 : yGutter)
        ForEach(trailingYLabels.filter { !$0.label.isEmpty }, id: \.self) { t in
            ChartLabel(t.label).placed(at: CGPoint(x: secondX, y: s.py(t.value)), anchor: .leading)
                .foregroundStyle(.secondary)
        }
    }

    /// x labels left to right, each kept only if it starts at least 4 pt after the previous one ends and ends inside
    /// the plot (Swift Charts' collision resolution hid the others).
    private func visibleXTicks(_ s: ChartScale) -> [ChartTick] {
        var kept: [ChartTick] = []
        var end = -CGFloat.infinity
        for t in xTicks.filter({ !$0.label.isEmpty }).sorted(by: { $0.value < $1.value }) {
            let x = s.px(t.value) + 4, w = ChartLabel(t.label).measured.width
            guard x >= end + 4, x + w <= s.plot.maxX + 0.5 else { continue }
            kept.append(t)
            end = x + w
        }
        return kept
    }

    /// The trailing gutter of the primary y labels (0 when they are on the leading edge or all empty).
    private var yGutter: CGFloat {
        let width = yTicks.map { $0.label.isEmpty ? 0 : ChartLabel($0.label).measured.width }.max() ?? 0
        return width > 0 ? width + Self.gap : 0
    }

    private func scale(in size: CGSize) -> ChartScale {
        let gap = Self.gap
        let lineHeight = ChartLabel("0").measured.height
        let secondWidth = trailingYLabels.map { $0.label.isEmpty ? 0 : ChartLabel($0.label).measured.width }.max() ?? 0
        let yGutter = self.yGutter
        let leading = leadingYLabels ? yGutter : 0
        let trailing = (leadingYLabels ? 0 : yGutter) + (secondWidth > 0 ? secondWidth + gap : 0)
        let bottom = xTicks.contains { !$0.label.isEmpty } ? lineHeight + 4 : 0
        let plot = CGRect(x: leading, y: 0, width: max(size.width - leading - trailing, 1), height: max(size.height - bottom, 1))
        return ChartScale(plot: plot, x: x, y: y)
    }
}

extension View {
    /// Frames the view to the plot rect and clips it a little outside it, so a line along an edge keeps its width.
    func chartPlot(_ s: ChartScale) -> some View {
        frame(width: s.plot.width, height: s.plot.height)
            .clipShape(Rectangle().inset(by: -2))
            .offset(x: s.plot.minX, y: s.plot.minY)
    }
}

// MARK: - Live history chart
// (RingBuffer, Sample, Bucket, Downsample, HistoryWindow live in ThermikCore/Model/HistoryModels.swift)

struct ChartSeries: Identifiable, Sendable {
    let id: String
    var name: String
    var color: Color
    var samples: [Sample]          // ALREADY downsampled to ≤ ~2 points per horizontal pixel
}

extension HistoryWindow {
    var title: LocalizedStringKey { switch self { case .m5: "5 min"; case .m15: "15 min"; case .h1: "1 h"; case .h6: "6 h"; case .h24: "24 h" } }
}

/// Hover state lives OUTSIDE the chart's inputs: writing it never re-evaluates the chart content.
/// Measured on M4 Max with 2×300 points and a 60 Hz moving hover (Swift Charts): selection inside the chart content
/// 60.7 % CPU, drawn in .chartOverlay 21.9 %, drawn in a sibling .overlay (this design) 5.8 %.
@MainActor @Observable final class ChartHover {
    var date: Date?
    var plot: CGRect = .zero
}

struct LiveHistoryChart: View {
    var series: [ChartSeries]
    var window: HistoryWindow
    var now: Date
    var yDomain: ClosedRange<Double> = 20...110
    var thresholds: [(label: String, celsius: Double, t: Double)] = LiveHistoryChart.defaultThresholds
    var unit: UnitTemperature = .celsius
    var showsArea = true
    var externalHover: ChartHover? = nil        // pass one in to share hover between stacked charts (or to probe)
    @State private var ownHover = ChartHover()
    @Environment(\.thermikRamp) private var ramp

    /// Dashed rules at hot (85 °C) and critical (100 °C) with 9-pt labels.
    static var defaultThresholds: [(label: String, celsius: Double, t: Double)] {
        [(String(localized: "Hot"), 85, 0.75), (String(localized: "Critical"), 100, 1.0)]
    }

    var body: some View {
        let hover = externalHover ?? ownHover
        let start = now.addingTimeInterval(-window.rawValue)
        let snap = max(1, window.rawValue / 600)  // quantise hover to ≈ one sample/bucket → fewer state changes
        let x = start.timeIntervalSinceReferenceDate...now.timeIntervalSinceReferenceDate
        // Ticks anchored to `now` (oscilloscope style): grid is static, data scrolls under it, labels never change.
        let xTicks = (0...5).map { i in
            let d = now.addingTimeInterval(-window.rawValue * Double(i) / 5)
            return ChartTick(value: d.timeIntervalSinceReferenceDate, label: Self.axisLabel(d, now: now, window: window))
        }
        let yTicks = ChartTick.stride(yDomain, by: 20) { ThermikFormat.temp($0, unit: unit) }
        ChartFrame(x: x, y: yDomain, xTicks: xTicks, yTicks: yTicks) { s in
            ZStack {
                if showsArea, let lead = series.first, let peak = lead.samples.map(\.value).max() {
                    // A single area under the primary series only — several get muddy.
                    ChartPath(lead.samples, xDomain: x, yDomain: yDomain, interpolation: .monotone, baseline: yDomain.lowerBound)
                        .fill(LinearGradient(colors: [lead.color.opacity(0.24), lead.color.opacity(0.0)], startPoint: .top, endPoint: .bottom)
                            .in(s.areaRect(peak: Double(peak), baseline: yDomain.lowerBound)))
                }
                ForEach(series) { ser in
                    ChartPath(ser.samples, xDomain: x, yDomain: yDomain, interpolation: .monotone)   // smooth, never overshoots
                        .stroke(ser.color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
                ForEach(thresholds, id: \.label) { th in
                    ChartPath.rule(y: th.celsius, xDomain: x, yDomain: yDomain)
                        .stroke(ramp.vivid(th.t).opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartPlot(s)
            ForEach(thresholds, id: \.label) { th in
                ChartLabel(th.label + " " + ThermikFormat.temp(th.celsius, unit: unit), size: 9, weight: .medium)
                    .placed(at: CGPoint(x: s.plot.minX, y: s.py(th.celsius) - 2), anchor: .bottomLeading)
                    .foregroundStyle(ramp.ink(th.t))
            }
            ChartHoverInput(hover: hover, scale: s, snap: snap)
        }
        .overlay(alignment: .topLeading) {                // sibling layer: hover changes re-render only this
            ChartHoverLayer(hover: hover, start: start, span: window.rawValue, series: series, unit: unit)
        }
        .transaction { $0.animation = nil }                // live data: no implicit morphing every tick
        // HistoryChartPanel adds the AXChartDescriptor (audio graph); this is the spoken summary.
        .accessibilityLabel(Text(series.map(\.name).joined(separator: ", ")))
        .accessibilityValue(Text(accessibilitySummary))
    }

    /// "latest 62°, minimum 48°, maximum 83°" per series (SPEC §4.13).
    private var accessibilitySummary: String {
        series.compactMap { s -> String? in
            guard let last = s.samples.last else { return nil }
            let vals = s.samples.map(\.value)
            let lo = Double(vals.min() ?? last.value), hi = Double(vals.max() ?? last.value)
            let summary = String(localized: "latest \(ThermikFormat.temp(Double(last.value), unit: unit)), minimum \(ThermikFormat.temp(lo, unit: unit)), maximum \(ThermikFormat.temp(hi, unit: unit))")
            return series.count > 1 ? s.name + ": " + summary : summary
        }.joined(separator: "; ")
    }

    /// Relative labels for short windows ("−4 min" … "now"), wall-clock for ≥ 6 h. Avoids the ambiguous "09:00" (mm:ss).
    static func axisLabel(_ d: Date, now: Date, window: HistoryWindow) -> String {
        if window.rawValue >= HistoryWindow.h6.rawValue { return d.formatted(.dateTime.hour().minute()) }
        let s = Int(now.timeIntervalSince(d).rounded())
        if s < 5 { return String(localized: "now") }
        if s >= 3600 {
            let h = (Double(s) / 3600).formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
            return String(localized: "−\(h) h", comment: "Chart axis: hours before now")
        }
        if s >= 60 { return String(localized: "−\(Int((Double(s) / 60).rounded())) min", comment: "Chart axis: minutes before now") }
        return String(localized: "−\(s) s", comment: "Chart axis: seconds before now")
    }
}

/// Transparent input layer over the plot (draws nothing): the time under the pointer, snapped, and the plot rect go
/// to `hover`.
struct ChartHoverInput: View {
    var hover: ChartHover
    var scale: ChartScale
    var snap: TimeInterval

    var body: some View {
        Rectangle().fill(.clear).contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let q = Date(timeIntervalSinceReferenceDate: (scale.xValue(atPlotOffset: p.x) / snap).rounded() * snap)
                    if hover.date != q { hover.date = q }
                case .ended:
                    hover.date = nil
                }
            }
            .chartPlot(scale)
            .onAppear { hover.plot = scale.plot }
            .onChange(of: scale.plot) { _, n in hover.plot = n }
    }
}

struct ChartHoverLayer: View {
    var hover: ChartHover
    var start: Date
    var span: TimeInterval
    var series: [ChartSeries]
    var unit: UnitTemperature = .celsius
    var body: some View {
        if let d = hover.date, hover.plot.width > 0 {
            let plot = hover.plot
            let x = plot.minX + CGFloat(d.timeIntervalSince(start) / span) * plot.width
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1, height: plot.height)
                    .offset(x: x, y: plot.minY)
                SelectionCallout(date: d, series: series, unit: unit)
                    .fixedSize()
                    .offset(x: x + 160 > plot.maxX ? x - 168 : x + 8, y: plot.minY + 4)   // flip near the right edge
            }
            .allowsHitTesting(false)
        }
    }
}

struct SelectionCallout: View {
    var date: Date
    var series: [ChartSeries]
    var unit: UnitTemperature = .celsius
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date, format: .dateTime.hour().minute().second()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(series) { s in
                if let v = nearest(s.samples, date) {
                    HStack(spacing: 6) {
                        Circle().fill(s.color).frame(width: 6, height: 6)
                        Text(s.name).font(.system(size: 11))
                        Spacer(minLength: 8)
                        Text(ThermikFormat.temp(Double(v.value), unit: unit, decimals: 1)).font(ThermikFont.valueSmall)
                    }
                }
            }
        }
        .padding(8)
        .frame(minWidth: 150)
        .thermikGlass(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private func nearest(_ s: [Sample], _ d: Date) -> Sample? {
        // binary search (samples are time-sorted)
        var lo = 0, hi = s.count - 1
        guard hi >= 0 else { return nil }
        while lo < hi { let mid = (lo + hi) / 2; if s[mid].time < d { lo = mid + 1 } else { hi = mid } }
        if lo > 0, abs(s[lo - 1].time.timeIntervalSince(d)) < abs(s[lo].time.timeIntervalSince(d)) { return s[lo - 1] }
        return s[lo]
    }
}

// Fan curve editor: App/MainWindow/Fans/FanCurveEditor.swift (Unit 8; percent-based, binds to Core [CurvePoint]).
