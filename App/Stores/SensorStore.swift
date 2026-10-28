// SensorStore.swift — Thermik (MIT). Minimal implementation by Unit 0; OWNER afterwards: Unit 5.
// Public surface (properties/methods below) is FROZEN; Unit 5 adds EMA smoothing, statistics, stale detection,
// spike rejection for hotspot roles and gated-cluster handling (SPEC §2.5.6).
//
// Smoothing (SENS §5.4): per sensor `ema += α·(x − ema)`, `α = 1 − exp(−dt/τ)`, τ = 2.8 s (α ≈ 0.30 at 1 s,
// 0.51 at 2 s; idle CPU-headline jitter 1.74 → 0.37 °C). Hotspot/maximum roles and the "hottest" aggregates first
// pass a median-of-3 spike filter (a single sample that jumps > 25 °C and reverts is dropped), then τ = 1.5 s.
// The average restarts after a gap of 5 nominal intervals and on the first tick after wake.
// States: gated clusters keep their last value (dimmed) for 30 s; a sensor that is no longer requested (its popover
// row closed) turns .stale WITHOUT a value after 3 intervals, so nothing acts on a frozen reading; when no frame
// arrives at all for 3 intervals (SamplingCoordinator's watchdog) every sensor turns .stale and KEEPS its value.
import Foundation
import Observation
import ThermikCore

enum SensorState: Sendable, Equatable {
    case ok
    case gated        // P-cluster power-gated ("Sleeping"/"Простаивает"); last value dimmed for ≤ 30 s, then "—"
    case invalid      // no valid reading
    case stale        // no update for > 3 intervals
}

/// Constants of the smoothing pipeline (SPEC §2.5.6).
enum SensorSmoothing {
    static let tau: TimeInterval = 2.8
    static let hotspotTau: TimeInterval = 1.5
    /// A gap longer than this many nominal intervals restarts the average.
    static let gapFactor = 5.0
    /// Gated clusters keep their last value (dimmed) this long, then show "—".
    static let gatedHoldSeconds: TimeInterval = 30
    /// A sensor (or the whole store) is stale after this many nominal intervals without a reading.
    static let staleFactor = 3.0
    /// Time-weighted statistics: one sample never counts for more than this (sensors read only while visible).
    static let maxStatWeight: TimeInterval = 10
    /// Aggregates smoothed like hotspot sensors (spike filter + τ 1.5 s).
    static let hotspotAggregates: Set<AggregateKind> = [.cpuHottest, .gpuHottest, .socHottest, .highestAll, .rawHottestDie]

    static func alpha(dt: TimeInterval, tau: TimeInterval) -> Double { 1 - exp(-max(dt, 0) / tau) }
    /// Published values are rounded to 0.01 °C: an unchanged reading then stops re-rendering its row.
    static func rounded(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

/// Median-of-3 spike rejection without delaying ordinary changes: a jump of more than 25 °C from the last
/// accepted value is held for one sample. If the next sample reverts, the jump was a spike and is dropped; if it
/// persists, it is accepted (one sample late — the same output as a median of three).
struct SpikeFilter: Sendable {
    static let jumpC = 25.0
    private var accepted: Double?
    private var pending: Double?

    mutating func reset() { accepted = nil; pending = nil }

    /// nil while a suspected spike is held (keep the previous output).
    mutating func filter(_ x: Double) -> Double? {
        guard let a = accepted else { accepted = x; return x }
        if pending != nil {
            pending = nil
            accepted = x                       // reverted (spike dropped) or persisted (step accepted)
            return x
        }
        if abs(x - a) > Self.jumpC { pending = x; return nil }
        accepted = x
        return x
    }
}

/// One sensor, observed individually so a row re-renders only when ITS value changes.
@MainActor @Observable final class LiveSensor: Identifiable {
    let sensor: Sensor
    nonisolated var id: SensorID { sensor.id }
    private(set) var value: Double?              // smoothed °C; nil when invalid (gated: last value for ≤ 30 s)
    private(set) var rawValue: Double?           // last decoded value (before sanity filter)
    private(set) var state: SensorState = .invalid
    private(set) var minValue: Double?           // session statistics (smoothed values) since launch / reset
    private(set) var maxValue: Double?
    private(set) var averageValue: Double?       // time-weighted
    @ObservationIgnored private var sum = 0.0    // Σ value · weight
    @ObservationIgnored private var count = 0.0  // Σ weight (s)
    var displayName: String
    var isHidden: Bool
    var isPinned: Bool

    // Smoothing state (Unit 5; not observed).
    @ObservationIgnored private var ema: Double?
    @ObservationIgnored private var spike = SpikeFilter()
    @ObservationIgnored private var lastStatDate: Date?
    /// Last tick that produced a valid reading.
    @ObservationIgnored private(set) var lastValidDate: Date?
    /// Last tick whose frame contained this sensor (valid, invalid or gated).
    @ObservationIgnored private(set) var lastSeenDate: Date?
    @ObservationIgnored let usesSpikeFilter: Bool
    @ObservationIgnored let tau: TimeInterval

    init(sensor: Sensor, displayName: String, isHidden: Bool, isPinned: Bool) {
        self.sensor = sensor; self.displayName = displayName; self.isHidden = isHidden; self.isPinned = isPinned
        let hotspot = sensor.role == .hotspot || sensor.role == .maximum
        usesSpikeFilter = hotspot
        tau = hotspot ? SensorSmoothing.hotspotTau : SensorSmoothing.tau
    }

    /// Applies one reading with the EMA factor already chosen for this tick (`alpha` ≥ 1 restarts the average at
    /// `valid`). Invalid → value nil; gated → the last value for ≤ 30 s, then nil. Statistics use smoothed values.
    func update(valid: Double?, raw: Double?, gated: Bool, alpha: Double, now: Date) {
        lastSeenDate = now
        if rawValue != raw { rawValue = raw }
        guard let v = valid else {
            let hold = gated && lastValidDate.map { now.timeIntervalSince($0) <= SensorSmoothing.gatedHoldSeconds } == true
            publish(hold ? ema : nil, gated ? .gated : .invalid)
            return
        }
        let a = alpha.isFinite ? min(max(alpha, 0), 1) : 1
        let next: Double
        if let e = ema, a < 1 { next = e + a * (v - e) } else { next = v }
        ema = next
        lastValidDate = now
        publish(next, .ok)
        accumulate(next, now: now)
    }

    /// SensorStore's per-tick entry: gap/wake restart, spike filter (hotspot roles), dt-based α, then `update`.
    func ingest(valid: Double?, raw: Double?, gated: Bool, now: Date, nominal: TimeInterval, restart: Bool) {
        guard let v = valid else { update(valid: nil, raw: raw, gated: gated, alpha: 1, now: now); return }
        let gap = lastValidDate.map { now.timeIntervalSince($0) } ?? .infinity
        let reset = restart || ema == nil || gap < 0 || gap > SensorSmoothing.gapFactor * nominal
        if reset { spike.reset() }
        if usesSpikeFilter, spike.filter(v) == nil, let held = ema {
            update(valid: held, raw: raw, gated: false, alpha: 0, now: now)         // suspected spike: hold
            return
        }
        update(valid: v, raw: raw, gated: false, alpha: reset ? 1 : SensorSmoothing.alpha(dt: gap, tau: tau), now: now)
    }

    /// The whole store went stale (no frame for > 3 nominal intervals): keep the last value, show it as stale
    /// (the menu bar adds "·").
    func markStale() { if state != .stale { state = .stale } }

    /// This sensor is no longer requested (its popover row or page closed): stale, and no value, so alerts and
    /// aggregate consumers never act on a frozen reading. The next request restarts the average (gap rule).
    func markNotSampled() {
        if state != .stale { state = .stale }
        if value != nil { value = nil }
    }

    func resetStatistics() {
        sum = 0; count = 0; lastStatDate = nil
        // Seed with the current reading so the row does not flash "—" until the next tick.
        let seed = state == .ok ? value : nil
        if minValue != seed { minValue = seed }
        if maxValue != seed { maxValue = seed }
        if averageValue != seed { averageValue = seed }
    }

    private func publish(_ v: Double?, _ s: SensorState) {
        let r = v.map(SensorSmoothing.rounded)
        if value != r { value = r }
        if state != s { state = s }
    }

    private func accumulate(_ v: Double, now: Date) {
        let r = SensorSmoothing.rounded(v)
        if minValue.map({ r < $0 }) ?? true { minValue = r }
        if maxValue.map({ r > $0 }) ?? true { maxValue = r }
        let w = lastStatDate.map { min(max(now.timeIntervalSince($0), 0), SensorSmoothing.maxStatWeight) } ?? 1
        lastStatDate = now
        guard w > 0 else { return }
        sum += v * w; count += w
        let avg = SensorSmoothing.rounded(sum / count)
        if averageValue != avg { averageValue = avg }
    }
}

@MainActor @Observable final class LiveSensorGroup: Identifiable {
    let group: DisplayGroup
    nonisolated var id: DisplayGroup { group }
    private(set) var sensors: [LiveSensor]
    private(set) var stat: GroupStat?
    init(group: DisplayGroup, sensors: [LiveSensor]) { self.group = group; self.sensors = sensors }
    func setSensors(_ s: [LiveSensor]) { sensors = s }
    func setStat(_ s: GroupStat?) { if stat != s { stat = s } }
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
    // Not observed: both change on every tick, and a view reading them would re-render every tick. Views use
    // `hasReading` / `isStale` / `showsStaleReadings`, which change only when staleness flips.
    @ObservationIgnored private(set) var lastFrame: SensorFrame?
    @ObservationIgnored private(set) var lastUpdate: Date?
    /// A frame has arrived (set once).
    private(set) var hasReading = false
    /// Sensor discovery failed (no SMC and no HID): the UI shows "Sensors unavailable". nil after a successful load.
    private(set) var loadError: String?
    /// Set by SamplingCoordinator's watchdog when no frame arrived for > 3 nominal intervals; cleared by a tick.
    private var staleMarked = false
    /// Nominal interval of the current sampling cadence (s). SamplingCoordinator sets it before every tick; it scales
    /// the gap restart and the staleness thresholds (1 s while the popover is open, the user's interval otherwise).
    @ObservationIgnored var nominalInterval: TimeInterval
    @ObservationIgnored private var byID: [SensorID: LiveSensor] = [:]
    @ObservationIgnored private var aggregator: SensorAggregator?
    @ObservationIgnored private var groupByID: [DisplayGroup: LiveSensorGroup] = [:]
    @ObservationIgnored private var visibleIDs: Set<SensorID> = []   // not hidden (aggregates: highestAll / averageAll)
    @ObservationIgnored private var shownIDs: Set<SensorID> = []     // listed (group stats)
    @ObservationIgnored private var aggregateState: [AggregateKind: AggregateSmoother] = [:]

    private struct AggregateSmoother {
        var ema: Double?
        var last: Date?
        var spike = SpikeFilter()
    }

    init(settings: SettingsStore) {
        self.settings = settings
        nominalInterval = settings.updateInterval
        // Settings UI toggles "Show hidden sensors"; resetToDefaults() clears the overrides.
        observeContinuously({ [weak settings] in
            _ = settings?.showHiddenSensors; _ = settings?.sensorOverrides
        }) { [weak self] in
            guard let self else { return false }
            self.applyOverrides()
            return true
        }
    }

    var isLoaded: Bool { inventory != nil }
    var isStale: Bool { !hasReading || staleMarked }
    /// Readings exist but stopped arriving: views dim them and show "Paused".
    var showsStaleReadings: Bool { hasReading && staleMarked }
    var pinned: [LiveSensor] { sensors.filter(\.isPinned) }
    /// Hottest visible die sensor (cpu/gpu/soc display groups) — popover header. Current readings win over
    /// stale ones (sensors not sampled while the popover was closed).
    var hottest: LiveSensor? {
        let dies = sensors.filter { !$0.isHidden && [.cpu, .gpu, .soc].contains($0.sensor.displayGroup) && $0.value != nil }
        let current = dies.filter { $0.state == .ok }
        return (current.isEmpty ? dies : current).max { ($0.value ?? 0) < ($1.value ?? 0) }
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
        loadError = nil
        aggregator = SensorAggregator(inventory: inventory)
        let ru = settings.preferRussian
        var seen = Set<SensorID>()
        sensors = inventory.sensors.compactMap { s in
            guard seen.insert(s.id).inserted else { return nil }             // ForEach identity needs unique ids
            if let existing = byID[s.id], existing.sensor == s { return existing }   // re-discovery keeps stats
            let o = settings.override(for: s.id)
            return LiveSensor(sensor: s, displayName: o.name ?? s.name(preferRussian: ru),
                              isHidden: o.hidden ?? !s.isVisibleByDefault, isPinned: o.pinned ?? false)
        }
        byID = Dictionary(uniqueKeysWithValues: sensors.map { ($0.id, $0) })
        rebuildGroups()
    }

    /// Discovery threw (SamplingCoordinator retries after wake).
    func loadFailed(_ error: any Error) {
        loadError = String(describing: error)
    }

    func rebuildGroups() {
        visibleIDs = Set(sensors.lazy.filter { !$0.isHidden }.map(\.id))
        let shown = sensors.filter { settings.showHiddenSensors || !$0.isHidden }
        shownIDs = Set(shown.map(\.id))
        var next: [LiveSensorGroup] = []
        for g in DisplayGroup.allCases {
            let members = shown.filter { $0.sensor.displayGroup == g }
            guard !members.isEmpty else { groupByID[g] = nil; continue }
            let group = groupByID[g] ?? LiveSensorGroup(group: g, sensors: members)   // keep identity for SwiftUI
            if group.sensors.map(\.id) != members.map(\.id) { group.setSensors(members) }
            groupByID[g] = group
            next.append(group)
        }
        if next.map(\.id) != groups.map(\.id) { groups = next }
    }

    func consume(_ tick: Tick) {
        let f = tick.sensors
        let now = tick.date
        let nominal = max(nominalInterval, 0.25)
        let restart = tick.isFirstAfterWake
        let staleAfter = SensorSmoothing.staleFactor * nominal
        var smoothed: [SensorID: Double] = [:]
        smoothed.reserveCapacity(f.values.count)
        var presentGroups = Set<DisplayGroup>()
        for s in sensors {
            let id = s.id
            let valid = f.values[id], raw = f.raw[id]
            // The 3 s post-wake window forces P-core keys invalid: that is not a power-gated cluster.
            let gated = f.gated.contains(id) && !f.isPostWake
            if valid != nil || raw != nil || f.gated.contains(id) {
                s.ingest(valid: valid, raw: raw, gated: gated, now: now, nominal: nominal, restart: restart)
                presentGroups.insert(s.sensor.displayGroup)
                if valid != nil, let v = s.value { smoothed[id] = v }
            } else if let seen = s.lastSeenDate, now.timeIntervalSince(seen) > staleAfter {
                s.markNotSampled()                                // not requested lately (popover closed)
            }
        }
        if let a = aggregator {
            let raw = a.aggregates(f.values, visible: visibleIDs)
            if raw != rawAggregates { rawAggregates = raw }
            let smooth = smoothAggregates(raw, now: now, nominal: nominal, restart: restart)
            if smooth != aggregates { aggregates = smooth }
            // Group headers summarize the smoothed values of the listed sensors; groups not read this tick keep theirs.
            let stats = a.groupStats(smoothed, visible: shownIDs)
            for g in groups where presentGroups.contains(g.group) { g.setStat(stats[g.group]) }
        }
        if power != f.power { power = f.power }
        lastFrame = f
        lastUpdate = now
        if !hasReading { hasReading = true }
        if staleMarked { staleMarked = false }
    }

    /// Watchdog (SamplingCoordinator): no frame for > 3 nominal intervals → every reading is stale.
    func markStale() {
        guard lastUpdate != nil, !staleMarked else { return }
        staleMarked = true
        for s in sensors where s.lastSeenDate != nil { s.markStale() }
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
    /// nil, empty or whitespace-only restores the database name.
    func rename(_ id: SensorID, to name: String?) {
        guard let s = byID[id] else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = (trimmed?.isEmpty ?? true) ? nil : trimmed
        s.displayName = custom ?? s.sensor.name(preferRussian: settings.preferRussian)
        var o = settings.override(for: id); o.name = custom; settings.setOverride(o, for: id)
    }

    /// Sensor ids the next tick must read. `includeAllVisible` when popover/Overview/Sensors page is visible.
    /// Always includes: headline sets, safety set, pinned, `extra` (alert subjects, menu bar sensor, log columns,
    /// fan-curve input, inspected sensor).
    func requestedSensorIDs(includeAllVisible: Bool, extra: Set<SensorID>) -> [SensorID] {
        guard let inv = inventory else { return [] }
        var ids = Set(inv.headline.values.flatMap { $0 }).union(inv.safetySet).union(extra)
        for s in sensors where s.isPinned { ids.insert(s.id) }
        if includeAllVisible { ids.formUnion(shownIDs) }
        return sensors.compactMap { ids.contains($0.id) ? $0.id : nil }
    }

    // MARK: Private

    /// Re-applies `settings.sensorOverrides` (after "Show hidden sensors", a rename elsewhere or a settings reset).
    private func applyOverrides() {
        let ru = settings.preferRussian
        for s in sensors {
            let o = settings.override(for: s.id)
            let name = o.name ?? s.sensor.name(preferRussian: ru)
            let hidden = o.hidden ?? !s.sensor.isVisibleByDefault
            let pinned = o.pinned ?? false
            if s.displayName != name { s.displayName = name }
            if s.isHidden != hidden { s.isHidden = hidden }
            if s.isPinned != pinned { s.isPinned = pinned }
        }
        rebuildGroups()
    }

    private func smoothAggregates(_ raw: AggregateValues, now: Date, nominal: TimeInterval, restart: Bool) -> AggregateValues {
        var out = AggregateValues(values: [:], sources: raw.sources)
        for (kind, x) in raw.values {
            var st = aggregateState[kind] ?? AggregateSmoother()
            let hotspot = SensorSmoothing.hotspotAggregates.contains(kind)
            let gap = st.last.map { now.timeIntervalSince($0) } ?? .infinity
            if restart || st.ema == nil || gap < 0 || gap > SensorSmoothing.gapFactor * nominal {
                st.ema = nil; st.spike.reset()
            }
            if let v = hotspot ? st.spike.filter(x) : x {           // nil: suspected spike held, keep the average
                if let e = st.ema {
                    st.ema = e + SensorSmoothing.alpha(dt: gap, tau: hotspot ? SensorSmoothing.hotspotTau : SensorSmoothing.tau) * (v - e)
                } else {
                    st.ema = v
                }
            }
            st.last = now
            aggregateState[kind] = st
            if let e = st.ema { out.values[kind] = SensorSmoothing.rounded(e) }
        }
        return out
    }
}
