// HistoryChartPanel.swift — Thermik (MIT). Unit 8. History charts for the main window (SPEC §4.11):
// ≤ 1 h → the kit's LiveHistoryChart (LTTB samples, hover in a sibling overlay layer, explicit domains, no implicit
// animation); 6 h / 24 h → a min/max envelope band + average line built from HistoryStore buckets, with the same
// hover design (ChartHover written by ChartHoverInput, drawn by the kit's ChartHoverLayer). Values are converted to the
// user's unit before plotting because the kit's axis labels print plain numbers. All charts are drawn with the kit
// (ChartFrame + ChartPath), not Swift Charts.
import Accessibility
import SwiftUI
import ThermikCore

struct HistorySeriesSpec: Identifiable, Hashable {
    let id: SeriesID
    var name: String
    var color: Color
}

struct HistoryChartPanel: View {
    var series: [HistorySeriesSpec]
    var window: HistoryWindow
    /// °C. nil = fitted to the data (rounded to 10° so it does not jitter every tick).
    var yDomain: ClosedRange<Double>? = 20...110
    var showsThresholds = true
    var height: CGFloat = 220
    var accessibilityTitle: String = String(localized: "Temperature history")

    @Environment(HistoryStore.self) private var history
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let _ = history.chartRevision(for: window)   // observation hook: refresh as often as this window can show
        let _ = settings.colorScales                 // the threshold rules follow the colour scale
        let unit = settings.effectiveUnit
        let now = Date()
        let envelope = window.rawValue >= HistoryWindow.h6.rawValue
        let data: [(spec: HistorySeriesSpec, samples: [Sample], buckets: [Bucket])] = series.map { s in
            if envelope {
                let b = history.buckets(s.id, window: window, columns: 360)
                return (s, b.map { Sample(time: $0.time, value: $0.avg) }, b)
            }
            return (s, history.samples(s.id, window: window, maxPoints: 300), [])
        }
        if data.allSatisfy({ $0.samples.count < 2 }) {
            SensorDataPlaceholder(height: height)              // temperatures: nothing arrives if discovery failed
        } else {
            let domain = Self.domain(yDomain, data.flatMap { $0.samples.map { Double($0.value) } }, unit: unit)
            let chartSeries = data.map { d in
                ChartSeries(id: "\(d.spec.id)", name: d.spec.name, color: d.spec.color,
                            samples: d.samples.map { Sample(time: $0.time, value: Float(WindowFormat.chartValue(Double($0.value), unit))) })
            }
            // "Hot" and "Critical" rules at the CPU/GPU colour scale's own stops (every series shown with them is a die
            // value), so they move with Settings › Appearance › Colour scale; `colorScales` above redraws the chart.
            let soc = ThermalScale.soc
            let thresholds: [(label: String, celsius: Double, t: Double)] = showsThresholds
                ? [ThermalLevel.hot, .critical]
                    .map { (label: $0.localizedTitle, celsius: WindowFormat.chartValue(soc.temps[$0.rawValue], unit), t: $0.stopT) }
                    .filter { domain.contains($0.celsius) }
                : []
            Group {
                if envelope {
                    EnvelopeHistoryChart(series: chartSeries,
                                         band: data.first.map { d in d.buckets.map {
                                             EnvelopeBand(time: $0.time, low: WindowFormat.chartValue(Double($0.min), unit),
                                                          high: WindowFormat.chartValue(Double($0.max), unit)) } } ?? [],
                                         window: window, now: now, yDomain: domain)
                } else {
                    LiveHistoryChart(series: chartSeries, window: window, now: now, yDomain: domain, thresholds: thresholds)
                }
            }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityTitle))
            .accessibilityValue(Text(verbatim: Self.summary(chartSeries, unit: unit)))
            .accessibilityChartDescriptor(HistoryChartDescriptor(title: accessibilityTitle, series: chartSeries.map {
                HistoryChartDescriptor.Series(name: $0.name, points: $0.samples.map { ($0.time.timeIntervalSince(now), Double($0.value)) })
            }, yRange: domain))
        }
    }

    /// Explicit domain in display units: the given °C range, or the data range padded and snapped to 10°.
    static func domain(_ fixed: ClosedRange<Double>?, _ celsius: [Double], unit: UnitTemperature) -> ClosedRange<Double> {
        if let fixed {
            return WindowFormat.chartValue(fixed.lowerBound, unit)...WindowFormat.chartValue(fixed.upperBound, unit)
        }
        let values = celsius.map { WindowFormat.chartValue($0, unit) }
        guard let lo = values.min(), let hi = values.max() else { return 20...110 }
        let low = ((lo - 4) / 10).rounded(.down) * 10
        let high = max(((hi + 4) / 10).rounded(.up) * 10, low + 20)
        return low...high
    }

    /// VoiceOver value: latest, min and max of each series.
    static func summary(_ series: [ChartSeries], unit: UnitTemperature) -> String {
        series.compactMap { s -> String? in
            guard let last = s.samples.last, let lo = s.samples.map(\.value).min(), let hi = s.samples.map(\.value).max() else { return nil }
            let latest = ThermikFormat.temp(Double(last.value)), min = ThermikFormat.temp(Double(lo)), max = ThermikFormat.temp(Double(hi))
            return String(localized: "\(s.name): now \(latest), minimum \(min), maximum \(max)")
        }.joined(separator: "; ")
    }
}

// MARK: - 6 h / 24 h envelope chart

struct EnvelopeBand: Hashable { var time: Date; var low: Double; var high: Double }

private struct EnvelopeHistoryChart: View {
    var series: [ChartSeries]
    var band: [EnvelopeBand]
    var window: HistoryWindow
    var now: Date
    var yDomain: ClosedRange<Double>
    @State private var hover = ChartHover()

    var body: some View {
        let start = now.addingTimeInterval(-window.rawValue)
        let snap = max(1, window.rawValue / 600)
        let x = start.timeIntervalSinceReferenceDate...now.timeIntervalSinceReferenceDate
        let xTicks = (0...6).map { i in
            let d = now.addingTimeInterval(-window.rawValue * Double(i) / 6)
            return ChartTick(value: d.timeIntervalSinceReferenceDate, label: d.formatted(.dateTime.hour().minute()))
        }
        ChartFrame(x: x, y: yDomain, xTicks: xTicks, yTicks: ChartTick.automatic(yDomain, count: 5) { ThermikFormat.temp($0) }) { s in
            ZStack {
                if let lead = series.first {
                    ChartPath(x: band.map { $0.time.timeIntervalSinceReferenceDate }, y: band.map(\.high), xDomain: x,
                              yDomain: yDomain, interpolation: .monotone, lower: band.map(\.low))
                        .fill(lead.color.opacity(0.18))
                }
                ForEach(series) { ser in
                    ChartPath(ser.samples, xDomain: x, yDomain: yDomain, interpolation: .monotone)
                        .stroke(ser.color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
            .chartPlot(s)
            ChartHoverInput(hover: hover, scale: s, snap: snap)
        }
        .overlay(alignment: .topLeading) {
            ChartHoverLayer(hover: hover, start: start, span: window.rawValue, series: series)
        }
        .transaction { $0.animation = nil }
    }
}

// MARK: - Audio graph / VoiceOver chart descriptor (§4.13)

struct HistoryChartDescriptor: AXChartDescriptorRepresentable {
    struct Series { var name: String; var points: [(seconds: Double, value: Double)] }
    var title: String
    var series: [Series]
    var yRange: ClosedRange<Double>
    /// The value axis: temperature, unless the chart plots W, %, rpm or the pressure level.
    var yTitle = String(localized: "Temperature")
    var format: (Double) -> String = { ThermikFormat.temp($0) }

    func makeChartDescriptor() -> AXChartDescriptor {
        let earliest = series.flatMap { $0.points.map(\.seconds) }.min() ?? -60
        let x = AXNumericDataAxisDescriptor(title: String(localized: "Seconds ago"), range: min(earliest, -1)...0,
                                            gridlinePositions: []) { v in WindowFormat.number(-v) }
        let format = self.format
        let y = AXNumericDataAxisDescriptor(title: yTitle, range: yRange, gridlinePositions: []) { v in format(v) }
        let data = series.map { s in
            AXDataSeriesDescriptor(name: s.name, isContinuous: true,
                                   dataPoints: s.points.map { AXDataPoint(x: $0.seconds, y: $0.value) })
        }
        return AXChartDescriptor(title: title, summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: data)
    }

    /// SwiftUI builds the descriptor once per view identity, then only calls this: copy the current data in.
    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let fresh = makeChartDescriptor()
        descriptor.title = fresh.title
        descriptor.summary = fresh.summary
        descriptor.xAxis = fresh.xAxis
        descriptor.yAxis = fresh.yAxis
        descriptor.series = fresh.series
    }
}

// MARK: - Non-temperature history (W, %, thermal pressure)

/// Simple live chart for one non-temperature series: watts, usage percent or the thermal-pressure step chart.
struct MetricHistoryChart: View {
    var id: SeriesID
    var window: HistoryWindow
    var color: Color = .accentColor
    var domain: ClosedRange<Double>? = nil        // nil = 0…(max rounded up)
    var stepped = false
    var height: CGFloat = 120
    var label: (Double) -> String
    var accessibilityTitle: String

    @Environment(HistoryStore.self) private var history

    var body: some View {
        let _ = history.chartRevision(for: window)
        let now = Date()
        let samples = window.rawValue >= HistoryWindow.h6.rawValue
            ? history.buckets(id, window: window, columns: 300).map { Sample(time: $0.time, value: $0.avg) }
            : history.samples(id, window: window, maxPoints: 400)
        if samples.count < 2 {
            CollectingDataPlaceholder(height: height)
        } else {
            let top = Double(samples.map(\.value).max() ?? 1)
            let y = domain ?? 0...max(10, (top * 1.15 / 10).rounded(.up) * 10)
            let x = now.addingTimeInterval(-window.rawValue).timeIntervalSinceReferenceDate...now.timeIntervalSinceReferenceDate
            let xTicks = (0...4).map { i in
                let d = now.addingTimeInterval(-window.rawValue * Double(i) / 4)
                return ChartTick(value: d.timeIntervalSinceReferenceDate, label: LiveHistoryChart.axisLabel(d, now: now, window: window))
            }
            ChartFrame(x: x, y: y, xTicks: xTicks, yTicks: ChartTick.automatic(y, count: stepped ? 5 : 4, label: label)) { s in
                ZStack {
                    if !stepped {
                        ChartPath(samples, xDomain: x, yDomain: y, interpolation: .monotone, baseline: y.lowerBound)
                            .fill(LinearGradient(colors: [color.opacity(0.2), color.opacity(0)], startPoint: .top, endPoint: .bottom)
                                .in(s.areaRect(peak: top, baseline: y.lowerBound)))
                    }
                    ChartPath(samples, xDomain: x, yDomain: y, interpolation: stepped ? .stepEnd : .monotone)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                .chartPlot(s)
            }
            .frame(height: height)
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityTitle))
            .accessibilityValue(Text(verbatim: samples.last.map { label(Double($0.value)) } ?? ""))
            .accessibilityChartDescriptor(HistoryChartDescriptor(
                title: accessibilityTitle,
                series: [.init(name: accessibilityTitle, points: samples.map { ($0.time.timeIntervalSince(now), Double($0.value)) })],
                yRange: y, yTitle: accessibilityTitle, format: label))
        }
    }
}

// MARK: - Fan rpm strip (stepped target + actual)

/// Thin chart under the temperature history: actual rpm per fan (lines) and the commanded target (stepEnd, dashed).
struct FanHistoryStrip: View {
    var fans: [(index: Int, name: String, maxRPM: Double)]
    var window: HistoryWindow
    var height: CGFloat = 70
    @Environment(HistoryStore.self) private var history

    var body: some View {
        let _ = history.chartRevision(for: window)
        let now = Date()
        let x = now.addingTimeInterval(-window.rawValue).timeIntervalSinceReferenceDate...now.timeIntervalSinceReferenceDate
        let maxRPM = fans.map(\.maxRPM).max() ?? 6000
        let lines = fans.map { f in
            FanLine(index: f.index, name: f.name, actual: history.samples(.fanRPM(f.index), window: window, maxPoints: 300),
                    target: history.samples(.fanTarget(f.index), window: window, maxPoints: 300))
        }
        if lines.allSatisfy({ $0.actual.count < 2 }) {
            EmptyView()
        } else {
            let y = 0...maxRPM
            ChartFrame(x: x, y: y, yTicks: [0, maxRPM / 2, maxRPM].map { ChartTick(value: $0, label: ThermikFormat.rpm($0)) }) { s in
                ZStack {
                    ForEach(lines, id: \.index) { line in
                        ChartPath(line.actual, xDomain: x, yDomain: y)
                            .stroke(Color.accentColor.opacity(line.index == 0 ? 1 : 0.6), style: StrokeStyle(lineWidth: 1.2))
                        ChartPath(line.target, xDomain: x, yDomain: y, interpolation: .stepEnd)
                            .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartPlot(s)
            }
            .frame(height: height)
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Fan speed history"))
            .accessibilityValue(Text(verbatim: lines.compactMap { l in
                l.actual.last.map { l.name + " " + ThermikFormat.rpmWithUnit(Double($0.value)) }
            }.joined(separator: ", ")))
            .accessibilityChartDescriptor(HistoryChartDescriptor(
                title: String(localized: "Fan speed history"),
                series: lines.map { l in .init(name: l.name, points: l.actual.map { ($0.time.timeIntervalSince(now), Double($0.value)) }) },
                yRange: y, yTitle: String(localized: "rpm"), format: { ThermikFormat.rpmWithUnit($0) }))
        }
    }

    private struct FanLine { var index: Int; var name: String; var actual: [Sample]; var target: [Sample] }
}
