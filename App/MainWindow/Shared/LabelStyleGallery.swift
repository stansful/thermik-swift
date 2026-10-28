// LabelStyleGallery.swift — Thermik (MIT). Unit 8. Live menu-bar style gallery (SPEC §4.4, §4.7 Menu Bar, §4.8 step 3):
// the MenuBarStyle previews rendered by the kit's MenuBarLabelRenderer from the current readings (CPU temperature
// and average fan speed), shown on a menu-bar-like strip. Selecting one writes `settings.menuBar.style`.
import AppKit
import SwiftUI
import ThermikCore

struct LabelStyleGallery: View {
    @Environment(SensorStore.self) private var sensors
    @Environment(FanStore.self) private var fans
    @Environment(SettingsStore.self) private var settings
    @Environment(HistoryStore.self) private var history
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme
    @State private var renderer = MenuBarLabelRenderer()

    var body: some View {
        let snapshot = Self.baseSnapshot(sensors: sensors, fans: fans, settings: settings, history: history)
        let readings = MenuBarReadings(sensors: sensors, fans: fans, history: history)
        let selected = settings.menuBar.style
        // Same options as the status item (MenuBarController.makeLabel): colour, alert colour and the colour-blind ramp.
        let options = MenuBarRenderOptions(colored: settings.menuBar.colored, alertColor: settings.menuBar.alertColor,
                                           colorBlind: settings.colorBlindScale, appearance: scheme == .dark ? .darkAqua : .aqua)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(MenuBarStyle.allCases) { style in
                let image = renderer.image(for: Self.snapshot(snapshot, style: style, settings: settings, readings: readings),
                                           style: style, options: options, scales: [displayScale])
                Button { settings.menuBar.style = style } label: {
                    VStack(spacing: 6) {
                        Image(nsImage: image)
                            .renderingMode(image.isTemplate ? .template : .original)
                            .foregroundStyle(.primary)
                            .frame(height: 22)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(.fill.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(verbatim: style.title).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .padding(8)
                    .background(style == selected ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: ThermikMetrics.innerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ThermikMetrics.innerRadius, style: .continuous)
                        .strokeBorder(style == selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: style == selected ? 2 : 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: style.title))
                .accessibilityAddTraits(style == selected ? .isSelected : [])
            }
        }
        if !fans.hasFans && sensors.isLoaded {
            Text("This Mac has no fans, so the menu bar always uses the Temperature style.")
                .font(ThermikFont.caption).foregroundStyle(.secondary)
        }
    }

    /// Composed styles get their own values (the same ones the status item resolves).
    static func snapshot(_ base: MenuBarSnapshot, style: MenuBarStyle, settings: SettingsStore,
                         readings: MenuBarReadings) -> MenuBarSnapshot {
        guard let label = style.composition(settings.menuBar) else { return base }
        var s = base
        s.composition = label
        s.composed = readings.composed(label)
        return s
    }

    /// Live values: the configured primary temperature (CPU average by default) and the average fan speed.
    static func baseSnapshot(sensors: SensorStore, fans: FanStore, settings: SettingsStore, history: HistoryStore) -> MenuBarSnapshot {
        let source: TemperatureSource = if case .temperature(let s) = settings.menuBar.primary { s } else { .aggregate(.cpuAverage) }
        let c = sensors.value(source) ?? sensors.hottest?.value ?? 62
        let running = fans.fans.filter { !$0.isOff }
        let rpm: Double? = fans.hasFans ? (running.isEmpty ? 0 : running.map(\.actualRPM).reduce(0, +) / Double(running.count))
                                        : (sensors.isLoaded ? nil : 1840)
        var s = MenuBarSnapshot(celsius: c, rpm: rpm, normalized: ThermalScale.soc.normalized(c), alert: false)
        s.fahrenheit = settings.effectiveUnit == .fahrenheit          // as the menu bar draws it (°F setting)
        // The mini graph previews the same 5-minute history the status item draws.
        let series = MenuBarController.seriesID(settings.menuBar.primary) ?? .aggregate(.cpuAverage)
        s.history = history.sparkline(series, points: 24).map(Double.init)
        return s
    }
}

/// One live label preview (the «Свой вариант» editor), drawn by the same renderer and values as the status item.
struct LabelPreview: View {
    var style: MenuBarStyle
    @Environment(SensorStore.self) private var sensors
    @Environment(FanStore.self) private var fans
    @Environment(SettingsStore.self) private var settings
    @Environment(HistoryStore.self) private var history
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme
    @State private var renderer = MenuBarLabelRenderer()

    var body: some View {
        let options = MenuBarRenderOptions(colored: settings.menuBar.colored, alertColor: settings.menuBar.alertColor,
                                           colorBlind: settings.colorBlindScale, appearance: scheme == .dark ? .darkAqua : .aqua)
        let base = LabelStyleGallery.baseSnapshot(sensors: sensors, fans: fans, settings: settings, history: history)
        let snapshot = LabelStyleGallery.snapshot(base, style: style, settings: settings,
                                                  readings: MenuBarReadings(sensors: sensors, fans: fans, history: history))
        let image = renderer.image(for: snapshot, style: style, options: options, scales: [displayScale])
        Image(nsImage: image)
            .renderingMode(image.isTemplate ? .template : .original)
            .foregroundStyle(.primary)
            .frame(height: 22)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.fill.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(Text(verbatim: image.accessibilityDescription ?? "Thermik"))
    }
}
