// OverviewPage.swift — Thermik (MIT). Unit 8. Overview (SPEC §4.6, DES §7.8): KPI tiles (Hottest with HeatGlow,
// thermal pressure, fans, power) on an aurora band, chip thermal map (only when the catalog has a die layout) or
// per-group bars, top-5 sensors with sparklines, live history (CPU / GPU / SoC hottest + fan rpm strip, hover callout
// in a separate overlay layer), diagnostics summary chips and a basic battery card.
import SwiftUI
import ThermikCore
import ThermikSMC

struct OverviewPage: View {
    @Bindable var model: MainWindowModel
    @Environment(SensorStore.self) private var sensors
    @Environment(SystemStore.self) private var system
    @Environment(FanStore.self) private var fans

    var body: some View {
        PageScroll {
            OverviewBanners(model: model)
            KPIRow(model: model)
            HStack(alignment: .top, spacing: ThermikMetrics.gutter) {
                if let layout = sensors.inventory?.dieLayout, !layout.isEmpty {
                    ChipMapCard(layout: layout)
                } else {
                    GroupBarsCard(model: model)
                }
                TopSensorsCard(model: model).frame(width: 300)
            }
            HistoryCard(model: model)
            HStack(alignment: .top, spacing: ThermikMetrics.gutter) {
                DiagnosticsSummaryCard(model: model)
                if system.hasBattery { BatterySummaryCard(model: model).frame(width: 300) }
            }
        }
    }
}

// MARK: - Banners (sensors unavailable, safety override, throttling, approximate names)

private struct OverviewBanners: View {
    var model: MainWindowModel
    @Environment(SensorStore.self) private var sensors
    @Environment(SystemStore.self) private var system
    @Environment(FanStore.self) private var fans
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        // Discovery failed (no SMC, no HID sensors) or found nothing: SensorStore.loadError / an empty inventory.
        if sensors.isUnavailable {
            StatusBanner(kind: .critical, symbol: "exclamationmark.octagon.fill",
                         text: String(localized: "Sensors unavailable: Thermik could not open the SMC.")) {
                Button { model.page = .diagnostics } label: { Text("Diagnostics") }
            }
        }
        if case .safetyOverride(let t) = fans.status {
            let temp = ThermikFormat.temp(t, unit: settings.effectiveUnit)
            StatusBanner(kind: .critical, symbol: "exclamationmark.octagon.fill",
                         text: String(localized: "Safety override: fans at maximum (\(temp))"))
        }
        if system.pressure >= .trapping {
            StatusBanner(kind: .warning, symbol: "thermometer.sun.fill",
                         text: String(localized: "macOS is throttling performance"))
        }
    }
}

// MARK: - KPI tiles

private struct KPIRow: View {
    var model: MainWindowModel
    @Environment(SystemStore.self) private var system
    @Environment(SettingsStore.self) private var settings
    @Environment(SensorStore.self) private var sensors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.thermikRamp) private var ramp

    var body: some View {
        HStack(alignment: .top, spacing: ThermikMetrics.gutter) {
            HottestTile(model: model, glowAnimates: !auroraAnimates)
            PressureTile()
            FansTile(model: model)
            PowerTile()
        }
        .padding(10)
        .background { band.clipShape(RoundedRectangle(cornerRadius: ThermikMetrics.cardRadius + 4, style: .continuous)) }
    }

    /// Aurora at pressure > nominal (12 fps, only with animated effects and without Reduce Motion); otherwise a static
    /// tint from the hottest value. While the aurora animates, the Hottest tile's glow shows a still frame: at most one
    /// effect animates at a time (ThermikEffects policy, as in the popover header).
    private var auroraAnimates: Bool { system.pressure > .nominal && settings.animatedEffects && !reduceMotion }

    @ViewBuilder private var band: some View {
        let t = sensors.hottest.flatMap { s in s.value.map { s.colorScale.normalized($0) } } ?? 0.3
        if auroraAnimates {
            AuroraBackground(normalized: t, energy: PressureLevel(system.pressure).energy)
        } else {
            LinearGradient(colors: [ramp.vivid(max(0, t - 0.1)).opacity(0.14), ramp.vivid(t).opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private struct HottestTile: View {
    var model: MainWindowModel
    var glowAnimates: Bool
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings
    @Environment(\.thermikRamp) private var ramp

    var body: some View {
        let hottest = sensors.hottest
        let value = hottest?.value
        let scale = hottest?.colorScale ?? .soc
        let t = value.map(scale.normalized) ?? 0
        MetricTile(title: String(localized: "Hottest"), symbol: "flame") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let value {
                    TemperatureText(celsius: value, scale: scale, font: ThermikFont.display, unit: settings.effectiveUnit)
                    LevelBadge(level: scale.level(value), compact: true)
                } else {
                    Text(verbatim: "—").font(ThermikFont.display).foregroundStyle(.tertiary)
                }
            }
        } footer: {
            Text(verbatim: hottest?.displayName
                 ?? (sensors.isUnavailable ? String(localized: "Sensors unavailable") : String(localized: "Collecting data…")))
        }
        .background {
            if settings.animatedEffects, t >= 0.70 {
                HeatGlow(intensity: HeatGlow.intensity(forNormalized: t), tint: ramp.vivid(t), animated: glowAnimates)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let id = hottest?.id { model.open(.sensors(id)) } }
        .help(Text("Show in Sensors"))
    }
}

private struct PressureTile: View {
    @Environment(SystemStore.self) private var system

    var body: some View {
        MetricTile(title: String(localized: "Thermal pressure"), symbol: "gauge.with.dots.needle.50percent") {
            HStack(spacing: 8) {
                Text(verbatim: system.pressure.title).font(ThermikFont.value).lineLimit(1).minimumScaleFactor(0.8)
                PressureChip(level: PressureLevel(system.pressure))
                    .labelStyle(.iconOnly)
            }
            .frame(minHeight: 34, alignment: .leading)
        } footer: {
            let n = system.pressureEventsToday
            if n == 0 { Text("No pressure events today") } else { Text("\(n) pressure events today") }
        }
    }
}

private struct FansTile: View {
    var model: MainWindowModel
    @Environment(FanStore.self) private var fans

    var body: some View {
        MetricTile(title: String(localized: "Fans"), symbol: "fan") {
            if !fans.hasFans {
                Text("Passively cooled — no fans").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(minHeight: 34, alignment: .leading)
            } else {
                let running = fans.fans.filter { !$0.isOff }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if running.isEmpty {
                        Text("Off").font(ThermikFont.display)
                    } else {
                        let avg = running.map(\.actualRPM).reduce(0, +) / Double(running.count)
                        Text(verbatim: ThermikFormat.rpm(avg)).font(ThermikFont.display)
                            .contentTransition(.numericText(value: avg))
                        Text("rpm").font(ThermikFont.unit).foregroundStyle(.secondary)
                    }
                    if fans.isOverriding {
                        Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(Color.accentColor)
                            .accessibilityLabel(Text("Thermik controls the fans"))
                    }
                }
            }
        } footer: {
            if fans.hasFans {
                if fans.fans.allSatisfy(\.isOff) && fans.mode == .system {
                    Text("Fans are off — macOS stopped them")
                } else {
                    Text(verbatim: fans.mode.title)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if fans.hasFans { model.page = .fans } }
    }
}

private struct PowerTile: View {
    @Environment(SensorStore.self) private var sensors
    @Environment(SystemStore.self) private var system

    var body: some View {
        let p = sensors.power
        MetricTile(title: String(localized: "Power"), symbol: "bolt") {
            if let w = p.systemTotalW {
                Text(verbatim: WindowFormat.watts(w)).font(ThermikFont.display)
                    .contentTransition(.numericText(value: w))
            } else {
                Text(verbatim: "—").font(ThermikFont.display).foregroundStyle(.tertiary)
            }
        } footer: {
            if let soc = p.socW {
                Text("SoC \(WindowFormat.watts(soc))")
            } else if let kind = system.powerSource?.kind {
                Text(verbatim: kind.title)
            }
        }
    }
}

// MARK: - Chip map (P1, needs dieLayout) and group bars

private struct ChipMapCard: View {
    var layout: [DieLayoutPoint]
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings
    @State private var hovered: DieSensor.ID?

    var body: some View {
        let points: [DieSensor] = layout.compactMap { p in
            guard let s = sensors.sensor(SensorID(databaseKey: p.key)), let v = s.value else { return nil }
            return DieSensor(id: s.id.description, label: s.displayName, position: CGPoint(x: p.x, y: p.y), celsius: v,
                             scale: s.colorScale)
        }
        PageCard(title: String(localized: "Chip thermal map"), symbol: "cpu") {
            if points.count < 3 {
                SensorDataPlaceholder(height: 220)
            } else {
                ThermalFieldView(sensors: points, hovered: $hovered)
                    .frame(height: 220)
                if let h = points.first(where: { $0.id == hovered }) {
                    Text(verbatim: "\(h.label) · \(ThermikFormat.temp(h.celsius, unit: settings.effectiveUnit))")
                        .font(ThermikFont.caption).foregroundStyle(.secondary)
                } else {
                    Text("Approximate die layout. Hover a dot for its sensor.").font(ThermikFont.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// One bar per display group: its hottest visible sensor on the group's own colour scale.
private struct GroupBarsCard: View {
    var model: MainWindowModel
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        PageCard(title: String(localized: "Sensor groups"), symbol: "square.grid.2x2") {
            if sensors.groups.isEmpty {
                SensorDataPlaceholder(height: 160)
            } else {
                VStack(spacing: 6) {
                    ForEach(sensors.groups) { g in GroupBarRow(group: g, unit: settings.effectiveUnit) { model.sensorGroupFilter = g.group; model.page = .sensors } }
                }
            }
        }
    }
}

private struct GroupBarRow: View {
    var group: LiveSensorGroup
    var unit: UnitTemperature
    var onOpen: () -> Void
    @Environment(\.thermikRamp) private var ramp

    var body: some View {
        let hottest = group.hottest
        let value = hottest?.value
        let scale = hottest?.colorScale ?? .soc
        let t = value.map(scale.normalized) ?? 0
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: group.group.symbol).foregroundStyle(.secondary).frame(width: 18)
                Text(verbatim: group.group.title).font(.system(size: 12)).lineLimit(1).frame(width: 150, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(ramp.vivid(t)).frame(width: max(g.size.height, g.size.width * t))
                    }
                }
                .frame(height: 6)
                Group {
                    if let value { TemperatureText(celsius: value, scale: scale, font: ThermikFont.valueSmall, unit: unit) }
                    else { Text(verbatim: "—").foregroundStyle(.tertiary) }
                }
                .frame(width: 48, alignment: .trailing)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Shows this group in Sensors"))
    }
}

// MARK: - Top sensors

private struct TopSensorsCard: View {
    var model: MainWindowModel
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let top = sensors.sensors.filter { !$0.isHidden && $0.value != nil }
            .sorted { ($0.value ?? 0) > ($1.value ?? 0) }
            .prefix(5)
        PageCard(title: String(localized: "Top sensors"), symbol: "list.number") {
            if top.isEmpty {
                SensorDataPlaceholder(height: 140)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(top)) { s in
                        TopSensorRow(sensor: s, unit: settings.effectiveUnit) { model.open(.sensors(s.id)) }
                    }
                }
            }
        }
    }
}

private struct TopSensorRow: View {
    var sensor: LiveSensor
    var unit: UnitTemperature
    var onOpen: () -> Void
    @Environment(HistoryStore.self) private var history

    var body: some View {
        let _ = history.sparklineRevision
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Text(verbatim: sensor.displayName).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Sparkline(values: history.sparkline(.sensor(sensor.id), points: 60), scale: sensor.colorScale, fill: false)
                    .frame(width: 60, height: 16)
                if let v = sensor.value {
                    TemperatureText(celsius: v, scale: sensor.colorScale, font: ThermikFont.valueSmall, unit: unit)
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - History

private struct HistoryCard: View {
    var model: MainWindowModel
    @Environment(FanStore.self) private var fans

    var body: some View {
        let series = [
            HistorySeriesSpec(id: .aggregate(.cpuAverage), name: AggregateKind.cpuAverage.title, color: .accentColor),
            HistorySeriesSpec(id: .aggregate(.gpuAverage), name: AggregateKind.gpuAverage.title, color: Color(nsColor: .systemPurple)),
            HistorySeriesSpec(id: .aggregate(.cpuHottest), name: AggregateKind.cpuHottest.title, color: Color(nsColor: .systemTeal)),
        ]
        PageCard(title: String(localized: "History"), symbol: "chart.xyaxis.line") {
            SeriesLegend(series: series)
        } content: {
            HistoryChartPanel(series: series, window: model.historyWindow, height: 220)
            if fans.hasFans {
                FanHistoryStrip(fans: fans.fans.map { ($0.id, $0.localizedName, $0.maxRPM) }, window: model.historyWindow)
            }
        }
    }
}

/// Custom legend chips (the kit hides the Charts legend).
struct SeriesLegend: View {
    var series: [HistorySeriesSpec]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(series) { s in
                HStack(spacing: 4) {
                    Circle().fill(s.color).frame(width: 7, height: 7)
                    Text(verbatim: s.name).font(ThermikFont.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Diagnostics + battery

private struct DiagnosticsSummaryCard: View {
    var model: MainWindowModel
    @Environment(DiagnosticsStore.self) private var diagnostics

    var body: some View {
        PageCard(title: String(localized: "Diagnostics"), symbol: "stethoscope") {
            Button { model.page = .diagnostics } label: { Text("Details") }
                .buttonStyle(.link).font(.system(size: 11))
        } content: {
            if diagnostics.items.isEmpty {
                Text("Diagnostics are collected in the background.").font(ThermikFont.caption).foregroundStyle(.secondary)
            } else {
                FlowChips(items: diagnostics.items.map { ($0.id.title, $0.status) }) { model.page = .diagnostics }
            }
        }
    }
}

/// Status chips that wrap onto several lines.
private struct FlowChips: View {
    var items: [(title: String, status: DiagnosticStatus)]
    var onTap: () -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.title) { item in
                Button(action: onTap) {
                    Label { Text(verbatim: item.title).lineLimit(1) } icon: {
                        Image(systemName: item.status.symbol).foregroundStyle(DiagnosticColors.color(item.status))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.fill.tertiary, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(item.title), \(item.status.title)"))
            }
        }
    }
}

private struct BatterySummaryCard: View {
    var model: MainWindowModel
    @Environment(SystemStore.self) private var system
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        PageCard(title: String(localized: "Battery"), symbol: "battery.75percent") {
            Button { model.page = .battery } label: { Text("Details") }
                .buttonStyle(.link).font(.system(size: 11))
        } content: {
            if let b = system.battery {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: b.chargePercent.map { WindowFormat.percent(Double($0)) } ?? "—").font(ThermikFont.value)
                    Text(verbatim: BatteryText.state(b)).font(ThermikFont.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let t = b.temperatureC {
                        TemperatureText(celsius: t, scale: .battery, font: ThermikFont.valueSmall, unit: settings.effectiveUnit)
                    }
                }
                if let h = b.healthPercent {
                    DetailRow(label: String(localized: "Battery health"), value: WindowFormat.percent(h))
                }
                if let c = b.cycleCount {
                    DetailRow(label: String(localized: "Cycle count"), value: "\(c) / \(b.designCycleCount ?? 1000)")
                }
            } else {
                CollectingDataPlaceholder(height: 60)
            }
        }
    }
}

enum DiagnosticColors {
    static func color(_ s: DiagnosticStatus) -> Color {
        switch s {
        case .ok: Color(nsColor: .systemGreen)
        case .info: Color(nsColor: .systemBlue)
        case .unknown: Color(nsColor: .tertiaryLabelColor)
        case .warning: Color(nsColor: .systemOrange)
        case .error: Color(nsColor: .systemRed)
        }
    }
}
