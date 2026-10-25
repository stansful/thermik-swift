// SensorStore.swift — Thermik (MIT). Minimal implementation by Unit 0; OWNER afterwards: Unit 5.
// Public surface (properties/methods below) is FROZEN; Unit 5 adds EMA smoothing, statistics, stale detection,
// spike rejection for hotspot roles and gated-cluster handling (SPEC §2.5.5).
import Foundation
import Observation
import ThermikCore

enum SensorState: Sendable, Equatable {
    case ok
    case gated        // P-cluster power-gated ("Sleeping"/"Простаивает"); last value dimmed for ≤ 30 s, then "—"
    case invalid      // no valid reading
    case stale        // no update for > 3 intervals
}

/// One sensor, observed individually so a row re-renders only when ITS value changes.
@MainActor @Observable final class LiveSensor: Identifiable {
    let sensor: Sensor
    nonisolated var id: SensorID { sensor.id }
    private(set) var value: Double?              // smoothed °C (Unit 5: EMA α≈0.3 @1 s); nil when invalid
    private(set) var rawValue: Double?           // last decoded value (before sanity filter)
    private(set) var state: SensorState = .invalid
    private(set) var minValue: Double?           // session statistics since launch / reset
    private(set) var maxValue: Double?
    private(set) var averageValue: Double?
    @ObservationIgnored private var sum = 0.0
    @ObservationIgnored private var count = 0
    var displayName: String
    var isHidden: Bool
    var isPinned: Bool

    init(sensor: Sensor, displayName: String, isHidden: Bool, isPinned: Bool) {
        self.sensor = sensor; self.displayName = displayName; self.isHidden = isHidden; self.isPinned = isPinned
    }

    /// Unit 0: no smoothing. Unit 5 replaces the body (alpha = EMA factor for this tick's dt).
    func update(valid: Double?, raw: Double?, gated: Bool, alpha: Double, now: Date) {
        rawValue = raw
        if let v = valid {
            value = v; state = .ok
            minValue = min(minValue ?? v, v); maxValue = max(maxValue ?? v, v)
            sum += v; count += 1; averageValue = sum / Double(count)
        } else {
            value = nil; state = gated ? .gated : .invalid
        }
    }

    func resetStatistics() { minValue = nil; maxValue = nil; averageValue = nil; sum = 0; count = 0 }
}

@MainActor @Observable final class LiveSensorGroup: Identifiable {
    let group: DisplayGroup
    nonisolated var id: DisplayGroup { group }
    private(set) var sensors: [LiveSensor]
    private(set) var stat: GroupStat?
    init(group: DisplayGroup, sensors: [LiveSensor]) { self.group = group; self.sensors = sensors }
    func setSensors(_ s: [LiveSensor]) { sensors = s }
    func setStat(_ s: GroupStat?) { stat = s }
    var hottest: LiveSensor? { sensors.filter { $0.value != nil }.max { ($0.value ?? 0) < ($1.value ?? 0) } }
}

@MainActor @Observable final class SensorStore: TickConsumer {
    @ObservationIgnored private let settings: SettingsStore
    private(set) var inventory: SensorInventory?
    private(set) var sensors: [LiveSensor] = []               // stable order after load(inventory:)
    private(set) var groups: [LiveSensorGroup] = []           // non-hidden sensors (or all with showHiddenSensors)
    private(set) var aggregates: AggregateValues = .empty     // smoothed (Unit 5)
    private(set) var rawAggregates: AggregateValues = .empty  // unsmoothed, this tick
    private(set) var power: PowerValues = .empty
    private(set) var lastFrame: SensorFrame?
    private(set) var lastUpdate: Date?
    @ObservationIgnored private var byID: [SensorID: LiveSensor] = [:]
    @ObservationIgnored private var aggregator: SensorAggregator?

    init(settings: SettingsStore) { self.settings = settings }

    var isLoaded: Bool { inventory != nil }
    var isStale: Bool { guard let d = lastUpdate else { return true }; return Date().timeIntervalSince(d) > 3 * max(settings.updateInterval, 1) }
    var pinned: [LiveSensor] { sensors.filter(\.isPinned) }
    /// Hottest visible die sensor (cpu/gpu/soc display groups) — popover header.
    var hottest: LiveSensor? {
        sensors.filter { !$0.isHidden && [.cpu, .gpu, .soc].contains($0.sensor.displayGroup) && $0.value != nil }
            .max { ($0.value ?? 0) < ($1.value ?? 0) }
    }

    func sensor(_ id: SensorID) -> LiveSensor? { byID[id] }

    /// Smoothed value for any engine / alert / menu bar input.
    func value(_ source: TemperatureSource) -> Double? {
        switch source {
        case .aggregate(let k): return aggregates[k]
        case .sensor(let id): return byID[id]?.value
        }
    }

    func load(inventory: SensorInventory) {
        self.inventory = inventory
        aggregator = SensorAggregator(inventory: inventory)
        let ru = settings.preferRussian
        sensors = inventory.sensors.map { s in
            let o = settings.override(for: s.id)
            return LiveSensor(sensor: s, displayName: o.name ?? s.name(preferRussian: ru),
                              isHidden: o.hidden ?? !s.isVisibleByDefault, isPinned: o.pinned ?? false)
        }
        byID = Dictionary(uniqueKeysWithValues: sensors.map { ($0.id, $0) })
        rebuildGroups()
    }

    func rebuildGroups() {
        let shown = sensors.filter { settings.showHiddenSensors || !$0.isHidden }
        groups = DisplayGroup.allCases.compactMap { g in
            let s = shown.filter { $0.sensor.displayGroup == g }
            return s.isEmpty ? nil : LiveSensorGroup(group: g, sensors: s)
        }
    }

    func consume(_ tick: Tick) {
        let f = tick.sensors
        for s in sensors where f.raw[s.id] != nil || f.values[s.id] != nil || f.gated.contains(s.id) {
            s.update(valid: f.values[s.id], raw: f.raw[s.id], gated: f.gated.contains(s.id), alpha: 1, now: tick.date)
        }
        let visible = Set(sensors.filter { !$0.isHidden }.map(\.id))
        if let a = aggregator {
            rawAggregates = a.aggregates(f.values, visible: visible)
            aggregates = rawAggregates
            let stats = a.groupStats(f.values, visible: visible)
            for g in groups { g.setStat(stats[g.group]) }
        }
        power = f.power
        lastFrame = f
        lastUpdate = tick.date
    }

    func resetStatistics() { sensors.forEach { $0.resetStatistics() } }

    func setHidden(_ id: SensorID, _ hidden: Bool) {
        guard let s = byID[id] else { return }
        s.isHidden = hidden
        var o = settings.override(for: id); o.hidden = hidden; settings.setOverride(o, for: id)
        rebuildGroups()
    }
    func setPinned(_ id: SensorID, _ pinned: Bool) {
        guard let s = byID[id] else { return }
        s.isPinned = pinned
        var o = settings.override(for: id); o.pinned = pinned; settings.setOverride(o, for: id)
    }
    func rename(_ id: SensorID, to name: String?) {
        guard let s = byID[id] else { return }
        s.displayName = name ?? s.sensor.name(preferRussian: settings.preferRussian)
        var o = settings.override(for: id); o.name = name; settings.setOverride(o, for: id)
    }

    /// Sensor ids the next tick must read. `includeAllVisible` when popover/Overview/Sensors page is visible.
    /// Always includes: headline sets, safety set, pinned, `extra` (alert subjects, menu bar sensor, log columns,
    /// fan-curve input, inspected sensor).
    func requestedSensorIDs(includeAllVisible: Bool, extra: Set<SensorID>) -> [SensorID] {
        guard let inv = inventory else { return [] }
        var ids = Set(inv.headline.values.flatMap { $0 }).union(inv.safetySet).union(extra).union(pinned.map(\.id))
        if includeAllVisible { ids.formUnion(sensors.filter { settings.showHiddenSensors || !$0.isHidden }.map(\.id)) }
        return sensors.map(\.id).filter { ids.contains($0) }
    }
}
