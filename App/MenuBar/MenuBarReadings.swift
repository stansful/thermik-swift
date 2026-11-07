// MenuBarReadings.swift — Thermik (MIT). Resolves menu bar metrics from the stores. Shared by the status item
// (MenuBarController) and the Settings style gallery / «Свой вариант» preview, so both show the same values.
import Foundation
import ThermikCore

@MainActor struct MenuBarReadings {
    let sensors: SensorStore
    let fans: FanStore
    let history: HistoryStore
    /// Fan metrics resolve to `.none` (and composed values drop them) on a Mac without fans.
    var fanless: Bool

    init(sensors: SensorStore, fans: FanStore, history: HistoryStore, fanless: Bool? = nil) {
        self.sensors = sensors; self.fans = fans; self.history = history
        self.fanless = fanless ?? (sensors.isLoaded && !fans.hasFans)
    }

    var maxRPM: Double { fans.fans.map(\.maxRPM).max() ?? 0 }

    func reading(_ metric: MenuBarMetric) -> MenuBarReading {
        switch metric {
        case .temperature(let source): return temperatureReading(source)
        case .fanAverage: return averageFanReading()
        case .fanMax: return maximumFanReading()
        case .fan(let i): return fanReading(i)
        case .systemPower: return systemPowerReading()
        case .none: return .none
        }
    }

    private func systemPowerReading() -> MenuBarReading {
        guard let w = sensors.power.systemTotalW else { return .unavailable(.watts) }
        return .watts(w)
    }

    private func temperatureReading(_ source: TemperatureSource) -> MenuBarReading {
        guard let v = sensors.value(source) else { return .unavailable(.temperature) }
        return .temperature(v, scale: scale(of: source))
    }

    private func averageFanReading() -> MenuBarReading {
        if fanless { return .none }
        let fans = fans.fans
        guard !fans.isEmpty, sensors.hasReading else { return .unavailable(.rpm) }
        return .rpm(fans.map(rpm).reduce(0, +) / Double(fans.count))
    }

    private func maximumFanReading() -> MenuBarReading {
        if fanless { return .none }
        guard let m = fans.fans.map(rpm).max(), sensors.hasReading else { return .unavailable(.rpm) }
        return .rpm(m)
    }

    private func fanReading(_ id: Int) -> MenuBarReading {
        if fanless { return .none }
        guard let f = fans.fans.first(where: { $0.id == id }), sensors.hasReading else { return .unavailable(.rpm) }
        return .rpm(rpm(f))
    }

    func scale(of source: TemperatureSource) -> ThermalScale {
        switch source {
        case .aggregate(let k): return .of(k)
        case .sensor(let id): return sensors.sensor(id).map { ThermalScale($0.sensor.thermalClass) } ?? .soc
        }
    }

    /// The values of a composed label in order; values with nothing to show (fans on a fanless Mac) are dropped.
    func composed(_ label: MenuBarCustomLabel) -> [MenuBarComposedValue] {
        label.items.compactMap { composedValue(for: $0) }
    }

    private func composedValue(for item: MenuBarLabelItem) -> MenuBarComposedValue? {
        let r = reading(item.metric)
        if case .none = r { return nil }
        return MenuBarComposedValue(reading: r, symbol: item.icon.symbol(for: item.metric),
                                    graphic: item.icon.isGraphic ? item.icon : .none,
                                    caption: String(item.caption.prefix(MenuBarLabelItem.captionLimit)),
                                    showUnit: item.showUnit, fraction: fraction(for: r), history: sparkline(for: item))
    }

    private func fraction(for reading: MenuBarReading) -> Double {
        switch reading {
        case .temperature(let c, let s): return s.normalized(c)
        case .rpm(let v): return maxRPM > 0 ? v / maxRPM : 0
        case .watts, .unavailable, .none: return 0
        }
    }

    private func sparkline(for item: MenuBarLabelItem) -> [Double] {
        guard item.icon == .graph, let id = MenuBarController.seriesID(item.metric) else { return [] }
        return history.sparkline(id, points: 24).map(Double.init)
    }

    private func rpm(_ f: LiveFan) -> Double { f.isOff ? 0 : f.actualRPM }
}
