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
        let fans = self.fans.fans
        switch metric {
        case .temperature(let source):
            guard let v = sensors.value(source) else { return .unavailable(.temperature) }
            return .temperature(v, scale: scale(of: source))
        case .fanAverage:
            if fanless { return .none }
            guard !fans.isEmpty, sensors.hasReading else { return .unavailable(.rpm) }
            return .rpm(fans.map(rpm).reduce(0, +) / Double(fans.count))
        case .fanMax:
            if fanless { return .none }
            guard let m = fans.map(rpm).max(), sensors.hasReading else { return .unavailable(.rpm) }
            return .rpm(m)
        case .fan(let i):
            if fanless { return .none }
            guard let f = fans.first(where: { $0.id == i }), sensors.hasReading else { return .unavailable(.rpm) }
            return .rpm(rpm(f))
        case .systemPower:
            guard let w = sensors.power.systemTotalW else { return .unavailable(.watts) }
            return .watts(w)
        case .none:
            return .none
        }
    }

    func scale(of source: TemperatureSource) -> ThermalScale {
        switch source {
        case .aggregate(let k): return .of(k)
        case .sensor(let id): return sensors.sensor(id).map { ThermalScale($0.sensor.thermalClass) } ?? .soc
        }
    }

    /// The values of a composed label in order; values with nothing to show (fans on a fanless Mac) are dropped.
    func composed(_ label: MenuBarCustomLabel) -> [MenuBarComposedValue] {
        label.items.compactMap { item in
            let r = reading(item.metric)
            if case .none = r { return nil }
            var fraction = 0.0
            switch r {
            case .temperature(let c, let s): fraction = s.normalized(c)
            case .rpm(let v): fraction = maxRPM > 0 ? v / maxRPM : 0
            case .watts, .unavailable, .none: break
            }
            let graph = item.icon == .graph
            let values = graph ? MenuBarController.seriesID(item.metric).map { history.sparkline($0, points: 24).map(Double.init) } ?? [] : []
            return MenuBarComposedValue(reading: r, symbol: item.icon.symbol(for: item.metric),
                                        graphic: item.icon.isGraphic ? item.icon : .none,
                                        caption: String(item.caption.prefix(MenuBarLabelItem.captionLimit)),
                                        showUnit: item.showUnit, fraction: fraction, history: values)
        }
    }

    private func rpm(_ f: LiveFan) -> Double { f.isOff ? 0 : f.actualRPM }
}
