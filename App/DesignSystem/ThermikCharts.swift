//  ThermikCharts.swift — history storage, downsampling, live chart, fan-curve editor (MIT).
import SwiftUI
import Charts
import ThermikCore

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

/// Hover state lives OUTSIDE the chart's inputs: writing it never re-evaluates the Chart content.
/// Measured on M4 Max with 2×300 points and a 60 Hz moving hover: selection inside Chart content 60.7 % CPU,
/// drawn in .chartOverlay 21.9 %, drawn in a sibling .overlay (this design) 5.8 %.
@MainActor @Observable final class ChartHover {
    var date: Date?
    var plot: CGRect = .zero
}

struct LiveHistoryChart: View {
    var series: [ChartSeries]
    var window: HistoryWindow
    var now: Date
    var yDomain: ClosedRange<Double> = 20...110
    var thresholds: [(label: String, celsius: Double, t: Double)] = [("Hot", 85, 0.75), ("Critical", 100, 1.0)]
    var showsArea = true
    var externalHover: ChartHover? = nil        // pass one in to share hover between stacked charts (or to probe)
    @State private var ownHover = ChartHover()

    var body: some View {
        let hover = externalHover ?? ownHover
        let start = now.addingTimeInterval(-window.rawValue)
        let snap = max(1, window.rawValue / 600)  // quantise hover to ≈ one sample/bucket → fewer state changes
        Chart {
            ForEach(series) { s in
                ForEach(s.samples, id: \.time) { p in
                    LineMark(x: .value("Time", p.time), y: .value("°C", p.value), series: .value("Sensor", s.id))
                        .foregroundStyle(s.color)
                        .interpolationMethod(.monotone)          // smooth, never overshoots (unlike catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
            if showsArea, let lead = series.first {   // single area under the primary series only — multiple areas get muddy
                ForEach(lead.samples, id: \.time) { p in
                    AreaMark(x: .value("Time", p.time), yStart: .value("Base", yDomain.lowerBound), yEnd: .value("°C", Double(p.value)))
                        .foregroundStyle(LinearGradient(colors: [lead.color.opacity(0.24), lead.color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(thresholds, id: \.label) { th in
                RuleMark(y: .value(th.label, th.celsius))
                    .foregroundStyle(ThermikPalette.vivid(th.t).opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("\(th.label) \(ThermikFormat.temp(th.celsius))").font(.system(size: 9, weight: .medium))
                            .foregroundStyle(ThermikPalette.ink(th.t))
                    }
            }
        }
        .chartXScale(domain: start...now)                 // sliding window; keep domain explicit → no re-layout jitter
        .chartYScale(domain: yDomain)
        .chartXAxis {
            // Ticks anchored to `now` (oscilloscope style): grid is static, data scrolls under it, labels never change.
            AxisMarks(values: (0...5).map { now.addingTimeInterval(-window.rawValue * Double($0) / 5) }) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.22))
                AxisValueLabel { if let d = v.as(Date.self) { Text(Self.axisLabel(d, now: now, window: window)) } }
            }
        }
        .chartYAxis { AxisMarks(position: .trailing, values: .stride(by: 20)) { v in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.22))
            AxisValueLabel { if let d = v.as(Double.self) { Text(ThermikFormat.temp(d)) } }
        } }
        .chartLegend(.hidden)                              // custom legend chips above the chart instead
        .chartOverlay { proxy in                           // input + plot-frame capture only; draws nothing
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            guard let d: Date = proxy.value(atX: p.x - plot.minX) else { return }
                            let q = Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / snap).rounded() * snap)
                            if hover.date != q { hover.date = q }
                        case .ended:
                            hover.date = nil
                        }
                    }
                    .onAppear { hover.plot = plot }
                    .onChange(of: plot) { _, n in hover.plot = n }
            }
        }
        .overlay(alignment: .topLeading) {                // sibling layer: hover changes re-render only this
            ChartHoverLayer(hover: hover, start: start, span: window.rawValue, series: series)
        }
        .transaction { $0.animation = nil }                // live data: no implicit morphing every tick
    }

    /// Relative labels for short windows ("−4 min" … "now"), wall-clock for ≥ 6 h. Avoids the ambiguous "09:00" (mm:ss).
    static func axisLabel(_ d: Date, now: Date, window: HistoryWindow) -> String {
        if window.rawValue >= HistoryWindow.h6.rawValue { return d.formatted(.dateTime.hour().minute()) }
        let s = Int(now.timeIntervalSince(d).rounded())
        if s < 5 { return String(localized: "now") }
        if s >= 3600 { return "−" + (Double(s) / 3600).formatted(.number.precision(.fractionLength(0...1))) + " h" }
        return s >= 60 ? "−\(Int((Double(s) / 60).rounded())) min" : "−\(s) s"
    }
}

struct ChartHoverLayer: View {
    var hover: ChartHover
    var start: Date
    var span: TimeInterval
    var series: [ChartSeries]
    var body: some View {
        if let d = hover.date, hover.plot.width > 0 {
            let plot = hover.plot
            let x = plot.minX + CGFloat(d.timeIntervalSince(start) / span) * plot.width
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1, height: plot.height)
                    .offset(x: x, y: plot.minY)
                SelectionCallout(date: d, series: series)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date, format: .dateTime.hour().minute().second()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(series) { s in
                if let v = nearest(s.samples, date) {
                    HStack(spacing: 6) {
                        Circle().fill(s.color).frame(width: 6, height: 6)
                        Text(s.name).font(.system(size: 11))
                        Spacer(minLength: 8)
                        Text(ThermikFormat.temp(Double(v.value), decimals: 1)).font(ThermikFont.valueSmall)
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
