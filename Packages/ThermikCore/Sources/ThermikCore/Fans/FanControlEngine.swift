// FanControlEngine.swift — Thermik (MIT).
// Pure logic (no I/O): (plan, temperatures, pressure, time) → per-fan commands `.system` or `.rpm(x)`.
// Runs in the unprivileged app at 1 Hz on the main actor (a non-Sendable class confined to its owner). The helper
// only actuates and enforces its own invariants; it never runs curves, so a crashed or quit app always ends in
// System mode (lease expiry).
//
// Port of research/fans/code/AppOnly/FanControlEngine.swift with the SPEC §2.9.2 changes:
//   * inputs are `TemperatureSource`s resolved (and smoothed) by SensorStore; the engine adds its own asymmetric
//     EMA per strategy, as in the source;
//   * thermal guard (P1): a pressure-based floor on top of any forced mode;
//   * safety latch on the smoothed `safetyTop4` OR the raw `rawHottestDie`, with a minimum latch time;
//   * fix: one EMA update per (source, time constants) per tick — the draft updated a shared EMA once per FAN,
//     so a linked two-fan plan smoothed twice as fast as configured;
//   * fix: a releasing curve engages at its first point (the draft engaged at first point − hysteresis, the same
//     threshold at which it released, so the fans could flap between System and manual);
//   * `resetState()` restarts slewing only: the safety latch, its smoothed input and the thermal guard survive a mode
//     change or a lost lease (a reset inside the latch's hysteresis band must not end the 100 % override);
//   * a power-gated input (an idle P cluster reads nothing) keeps its last smoothed value instead of the sensor-lost
//     fail-safe (≥ 50 %); EMAs no strategy used this tick are dropped, so the editor's operating point never freezes.
// Algorithm notes (independent design; ideas cross-checked with the MIT-licensed estevecastells/macfanoptimizer
// docs/ARCHITECTURE.md): asymmetric EMA (fast up, slow down), slew limits in %/s, hold-before-decrease,
// hysteresis in °C; 0 % == F%dMn, 100 % == F%dMx, "off" only via System; critical override → every non-System
// fan to 100 %; Ftst hardware (M3/M4) is all-or-nothing: System fans inherit the highest demand.
import Foundation
import ThermikSMC

public final class FanControlEngine {
    public let profile: FanHardwareProfile
    /// Output deadband: changes smaller than this are sent only once stable for `settleSeconds`.
    public var writeDeadbandRPM: Double = 50
    public var settleSeconds: Double = 5
    /// Nominal tick (s). A gap above `sleepGapFactor` × nominal resets the filters (sleep/wake, stalls).
    public var nominalTick: Double = 1
    public var sleepGapFactor: Double = 5
    /// Once tripped, the safety latch holds at least this long (a single raw spike must not toggle the fans).
    public var safetyMinLatchSeconds: Double = 10
    /// Internal "percent" of a stopped fan (curve option `stop`): below every real speed, sent as 0 rpm. The safety
    /// latch and the thermal guard lift it like any other value.
    static let stoppedPercent: Double = -1
    public private(set) var safetyLatched = false
    public private(set) var thermalGuardActive = false
    /// Smoothed safety temperature (fast-up / slow-down EMA of `safetyTempC`), for UI and events.
    public private(set) var safetyTemperatureC: Double?

    private struct FanState {
        var percent: Double? = nil                   // nil == System
        var lastDemandAboveAt: Date? = nil           // hold-before-decrease
        var autoMaxLatchedAt: Date? = nil
        var lastSentRPM: Double? = nil
        var pendingRPM: Double? = nil                // small change waiting to settle
        var pendingSince: Date? = nil
    }

    /// One EMA per input and time-constant pair (strategies may smooth the same sensor differently).
    private struct EMAKey: Hashable {
        let source: TemperatureSource
        let rise: Double
        let fall: Double
    }

    private var fans: [Int: FanState] = [:]
    private var ema: [EMAKey: Double] = [:]
    /// EMAs a strategy read this tick (updated, or held for a gated input); the others are dropped after the tick.
    private var usedThisTick: Set<EMAKey> = []
    /// Inputs whose sensor is power-gated this tick (see `tick(now:temperatures:gated:…)`).
    private var gatedInputs: Set<TemperatureSource> = []
    private var safetyEMA: Double?
    private var lastSafetyTripAt: Date?
    private var lastTick: Date?
    private var pressureElevatedSince: Date?
    private var pressureNominalSince: Date?
    private var guardEngaged = false

    public init(profile: FanHardwareProfile) { self.profile = profile }

    /// Call after the helper reverted (sleep, lease expiry), after wake and on every mode change, so slewing
    /// restarts from scratch. Per-fan slew / hold / deadband state and the input EMAs restart; the safety latch (with
    /// its smoothed input and minimum latch time) and the thermal guard do NOT: re-selecting a mode or a macOS
    /// reclaim inside the latch's hysteresis band must not end the 100 % override (SPEC §2.9.2 item 3). `lastTick`
    /// stays too, so a long pause (sleep, System mode) still counts as a gap on the next tick and re-seeds them.
    public func resetState() {
        fans.removeAll(); ema.removeAll(); usedThisTick.removeAll()
    }

    /// Latest engine-smoothed value of `source` (the curve editor's live operating point). nil before the first
    /// tick that used it. Only EMAs used on the last tick are kept, so this is the active strategy's value.
    public func smoothedTemperature(_ source: TemperatureSource) -> Double? {
        ema.first { $0.key.source == source }?.value
    }

    /// - temperatures: resolved values for `plan.referencedSources` (smoothed).
    /// - safetyTempC: AggregateKind.safetyTop4 (smoothed); rawHottestC: AggregateKind.rawHottestDie (raw).
    public func tick(now: Date, temperatures: [TemperatureSource: Double], safetyTempC: Double?, rawHottestC: Double?,
                     pressure: ThermalPressure, plan: FanPlan) -> [Int: FanCommand] {
        tick(now: now, temperatures: temperatures, gated: [], safetyTempC: safetyTempC, rawHottestC: rawHottestC,
             pressure: pressure, plan: plan)
    }

    /// Same, with the inputs whose sensor is power-gated (missing from `temperatures` because its P cluster is idle,
    /// not because the sensor failed). A gated input keeps its last smoothed value; without one the current speed
    /// is held (System stays System). Only a truly missing input gets the fail-safe (hold, ≥ 50 %).
    public func tick(now: Date, temperatures: [TemperatureSource: Double], gated: Set<TemperatureSource>,
                     safetyTempC: Double?, rawHottestC: Double?, pressure: ThermalPressure,
                     plan: FanPlan) -> [Int: FanCommand] {
        let dt = prepareTick(now: now)
        usedThisTick.removeAll()
        gatedInputs = gated
        updateSafety(now: now, dt: dt, safetyTempC: safetyTempC, rawHottestC: rawHottestC, plan: plan)
        let guardFloor = updateThermalGuard(now: now, pressure: pressure, config: plan.thermalGuard)
        var percents = desiredPercents(temperatures: temperatures, dt: dt, now: now, plan: plan, guardFloor: guardFloor)
        applyAllOrNothing(to: &percents)
        let out = commands(now: now, percents: percents)
        ema = ema.filter { usedThisTick.contains($0.key) }     // an EMA of a strategy no longer in use is stale
        return out
    }

    /// A long gap means sleep, a stall, or a long interval in System mode: restart filters and pressure timing.
    private func prepareTick(now: Date) -> Double {
        var dt = lastTick.map { now.timeIntervalSince($0) } ?? nominalTick
        if dt <= 0 { dt = nominalTick }
        if dt > sleepGapFactor * nominalTick {
            resetAfterGap()
            dt = nominalTick
        }
        lastTick = now
        return dt
    }

    private func resetAfterGap() {
        ema.removeAll()
        safetyEMA = nil
        pressureElevatedSince = nil
        pressureNominalSince = nil
        guardEngaged = false
    }

    private func desiredPercents(temperatures: [TemperatureSource: Double], dt: Double, now: Date,
                                 plan: FanPlan, guardFloor: Double?) -> [Int: Double?] {
        var percents: [Int: Double?] = [:]
        var guardApplied = false
        for fan in profile.fans {
            let p = fanPercent(fan, temperatures: temperatures, dt: dt, now: now, plan: plan,
                               guardFloor: guardFloor, guardApplied: &guardApplied)
            percents[fan.index] = p
        }
        thermalGuardActive = guardApplied
        return percents
    }

    /// System remains macOS's alone. The guard floors forced speeds; safety jumps to 100 % without slew.
    private func fanPercent(_ fan: FanDescriptor, temperatures: [TemperatureSource: Double], dt: Double,
                            now: Date, plan: FanPlan, guardFloor: Double?, guardApplied: inout Bool) -> Double? {
        var st = fans[fan.index] ?? FanState()
        let strategy = plan.strategy(for: fan.index)
        resetStoppedSentinel(for: strategy, state: &st)
        var p = desiredPercent(strategy, fan: fan, state: &st, temps: temperatures, dt: dt, now: now, plan: plan)
        let isSystem: Bool = if case .system = strategy { true } else { false }
        p = applyGuardFloor(guardFloor, to: p, applied: &guardApplied)
        if safetyLatched && !isSystem { p = 100 }
        st.percent = p
        fans[fan.index] = st
        return p
    }

    private func applyGuardFloor(_ floor: Double?, to percent: Double?, applied: inout Bool) -> Double? {
        guard let floor, let current = percent else { return percent }
        applied = true
        return max(current, floor)
    }

    /// Ftst hardware: never leave a fan in firmware mode 0 while another is forced.
    private func applyAllOrNothing(to percents: inout [Int: Double?]) {
        guard profile.scheme.requiresAllOrNothing else { return }
        let demands = percents.values.compactMap { $0 }
        guard let maxDemand = demands.max(), demands.count < profile.fans.count else { return }
        for fan in profile.fans where percents[fan.index] == .some(nil) {
            percents[fan.index] = maxDemand
            fans[fan.index]?.percent = maxDemand
        }
    }

    private func commands(now: Date, percents: [Int: Double?]) -> [Int: FanCommand] {
        var out: [Int: FanCommand] = [:]
        for fan in profile.fans {
            out[fan.index] = command(fan: fan, percent: percents[fan.index] ?? nil, now: now)
        }
        return out
    }

    private func command(fan: FanDescriptor, percent: Double?, now: Date) -> FanCommand {
        guard let p = percent else {
            resetSystemFan(fan.index)
            return .system
        }
        return rpmCommand(fan: fan, percent: p, now: now)
    }

    private func resetSystemFan(_ index: Int) {
        fans[index]?.lastSentRPM = nil
        fans[index]?.pendingRPM = nil
        fans[index]?.pendingSince = nil
    }

    private func rpmCommand(fan: FanDescriptor, percent: Double, now: Date) -> FanCommand {
        let rpm = percent < 0 ? 0 : fan.clamp(fan.rpm(forPercent: percent)).rounded()   // stopped → 0 rpm
        var st = fans[fan.index] ?? FanState()
        defer { fans[fan.index] = st }
        let atExtreme = rpm <= fan.minRPM || rpm >= fan.maxRPM
        if let last = st.lastSentRPM, abs(last - rpm) < writeDeadbandRPM, !atExtreme {
            return deadbandCommand(rpm: rpm, last: last, now: now, state: &st)
        }
        return acceptRPM(rpm, state: &st)
    }

    /// Keep the last write inside the deadband unless the small change has been stable for `settleSeconds`.
    private func deadbandCommand(rpm: Double, last: Double, now: Date, state st: inout FanState) -> FanCommand {
        if abs(last - rpm) >= 1, let pending = st.pendingRPM, abs(pending - rpm) < 1, let since = st.pendingSince,
           now.timeIntervalSince(since) >= settleSeconds { return acceptRPM(rpm, state: &st) }
        if st.pendingRPM.map({ abs($0 - rpm) >= 1 }) ?? true { recordPending(rpm, now: now, state: &st) }
        return .rpm(last)
    }

    private func acceptRPM(_ rpm: Double, state st: inout FanState) -> FanCommand {
        st.lastSentRPM = rpm
        st.pendingRPM = nil
        st.pendingSince = nil
        return .rpm(rpm)
    }

    private func recordPending(_ rpm: Double, now: Date, state st: inout FanState) {
        st.pendingRPM = rpm
        st.pendingSince = now
    }

    // MARK: Safety (SPEC §2.9.2 item 3)

    private func updateSafety(now: Date, dt: Double, safetyTempC: Double?, rawHottestC: Double?, plan: FanPlan) {
        updateSafetyEMA(dt: dt, safetyTempC: safetyTempC)
        let cfg = plan.safety
        let smoothedTrip = safetyEMA.map { $0 >= cfg.criticalC } ?? false
        let rawTrip = rawHottestC.map { $0.isFinite && $0 >= cfg.rawCriticalC } ?? false
        if smoothedTrip || rawTrip {
            safetyLatched = true
            lastSafetyTripAt = now
        } else if shouldReleaseSafety(now: now, config: cfg) {
            safetyLatched = false
        }
    }

    private func updateSafetyEMA(dt: Double, safetyTempC: Double?) {
        if let s = safetyTempC, s.isFinite {
            safetyEMA = smooth(previous: safetyEMA, raw: s, dt: dt, rise: 1, fall: 6)
        }
        safetyTemperatureC = safetyEMA
    }

    /// A missing safety input keeps the latch (fail safe); release requires cooling and the minimum latch time.
    private func shouldReleaseSafety(now: Date, config cfg: SafetyConfig) -> Bool {
        guard safetyLatched, let sm = safetyEMA else { return false }
        let cooled = sm < cfg.criticalC - cfg.hysteresisC
        let held = now.timeIntervalSince(lastSafetyTripAt ?? .distantPast) >= safetyMinLatchSeconds
        return cooled && held
    }

    // MARK: Thermal guard (P1, SPEC §2.9.2 item 2)

    /// Returns the floor (%) while the guard is engaged, else nil.
    private func updateThermalGuard(now: Date, pressure: ThermalPressure, config g: ThermalGuardConfig) -> Double? {
        guard g.enabled else {
            disableThermalGuard()
            return nil
        }
        updatePressureState(now: now, pressure: pressure, config: g)
        guard guardEngaged else { return nil }
        let floor = pressure >= .heavy ? g.heavyPercent : g.moderateFloorPercent
        return min(max(floor, 0), 100)
    }

    private func disableThermalGuard() {
        guardEngaged = false
        pressureElevatedSince = nil
        pressureNominalSince = nil
    }

    private func updatePressureState(now: Date, pressure: ThermalPressure, config g: ThermalGuardConfig) {
        if pressure >= .moderate {
            notePressureElevated(now: now, config: g)
        } else {
            notePressureNominal(now: now, config: g)
        }
    }

    private func notePressureElevated(now: Date, config g: ThermalGuardConfig) {
        pressureNominalSince = nil
        let since = pressureElevatedSince ?? now
        pressureElevatedSince = since
        if !guardEngaged, now.timeIntervalSince(since) >= g.engageAfterSeconds { guardEngaged = true }
    }

    private func notePressureNominal(now: Date, config g: ThermalGuardConfig) {
        pressureElevatedSince = nil
        guard guardEngaged else { return }
        let since = pressureNominalSince ?? now
        pressureNominalSince = since
        if now.timeIntervalSince(since) >= g.releaseAfterSeconds {
            guardEngaged = false
            pressureNominalSince = nil
        }
    }

    // MARK: Strategy evaluation

    /// The stopped sentinel is only meaningful to a stopping curve: anything else starts from scratch (jump to its
    /// own value) instead of slewing up from -1 %.
    private func resetStoppedSentinel(for s: FanStrategy, state st: inout FanState) {
        if st.percent == Self.stoppedPercent, !Self.stopsBelowFirstPoint(s) { st.percent = nil }
    }

    private func desiredPercent(_ s: FanStrategy, fan: FanDescriptor, state st: inout FanState,
                                temps: [TemperatureSource: Double], dt: Double, now: Date, plan: FanPlan) -> Double? {
        switch s {
        case .system: return systemPercent(state: &st)
        case .fixedRPM(let r): return fixedRPMPercent(r, fan: fan, plan: plan)
        case .fixedPercent(let p): return fixedPercentValue(p, plan: plan)
        case let .autoMax(sensor, threshold, hyst, minHold): return autoMaxPercent(sensor, threshold: threshold, hyst: hyst, minHold: minHold, temps: temps, dt: dt, now: now, state: &st)
        case let .autoBoost(sensor, lowC, highC, minP, maxP, gradual, hyst):
            return autoBoostPercent(sensor, lowC: lowC, highC: highC, minP: minP, maxP: maxP, gradual: gradual, hyst: hyst, temps: temps, dt: dt, state: &st)
        case let .curve(sensor, points, hyst, below, smoothing, slewCfg):
            return curvePercent(sensor, points: points, hyst: hyst, below: below, smoothing: smoothing, slewCfg: slewCfg, temps: temps, dt: dt, now: now, state: &st)
        }
    }

    private func systemPercent(state st: inout FanState) -> Double? {
        st.autoMaxLatchedAt = nil
        return nil
    }

    private func fixedRPMPercent(_ rpm: Double, fan: FanDescriptor, plan: FanPlan) -> Double? {
        guard rpm.isFinite else { return nil }
        return applyFixedFloor(fan.percent(forRPM: rpm), plan: plan)
    }

    private func fixedPercentValue(_ percent: Double, plan: FanPlan) -> Double? {
        guard percent.isFinite else { return nil }
        return applyFixedFloor(min(max(percent, 0), 100), plan: plan)
    }

    private func autoMaxPercent(_ sensor: TemperatureSource, threshold: Double, hyst: Double, minHold: Double,
                                temps: [TemperatureSource: Double], dt: Double, now: Date, state st: inout FanState) -> Double? {
        guard let t = smoothed(sensor, temps, dt: dt, rise: 1, fall: 6) else { return inputMissing(sensor, st) }
        if let since = st.autoMaxLatchedAt {
            return latchedAutoMaxPercent(t, threshold: threshold, hyst: hyst, minHold: minHold, since: since, now: now, state: &st)
        }
        if t >= threshold {
            st.autoMaxLatchedAt = now
            return 100
        }
        return nil
    }

    private func latchedAutoMaxPercent(_ t: Double, threshold: Double, hyst: Double, minHold: Double,
                                       since: Date, now: Date, state st: inout FanState) -> Double? {
        if t < threshold - hyst && now.timeIntervalSince(since) >= minHold {
            st.autoMaxLatchedAt = nil
            return nil
        }
        return 100
    }

    private func autoBoostPercent(_ sensor: TemperatureSource, lowC: Double, highC: Double, minP: Double, maxP: Double,
                                  gradual: Double, hyst: Double, temps: [TemperatureSource: Double], dt: Double,
                                  state st: inout FanState) -> Double? {
        guard let t = smoothed(sensor, temps, dt: dt, rise: 1, fall: 6) else { return inputMissing(sensor, st) }
        let active = st.percent != nil
        let rate = 100 / max(gradual, 1)
        if !active && t < lowC { return nil }
        if active && t < lowC - hyst { return releasingAutoBoostPercent(minP: minP, rate: rate, dt: dt, state: &st) }
        let span = max(highC - lowC, 0.1)
        let target = minP + (maxP - minP) * min(max((t - lowC) / span, 0), 1)
        return slew(from: st.percent ?? minP, to: target, dt: dt, up: rate, down: rate)
    }

    /// Ramp down gradually, then release.
    private func releasingAutoBoostPercent(minP: Double, rate: Double, dt: Double, state st: inout FanState) -> Double? {
        let next = slew(from: st.percent ?? minP, to: minP, dt: dt, up: rate, down: rate)
        return next <= minP + 0.01 ? nil : next
    }

    private func curvePercent(_ sensor: TemperatureSource, points: [CurvePoint], hyst: Double, below: BelowFirstPoint,
                              smoothing: Smoothing, slewCfg: Slew, temps: [TemperatureSource: Double], dt: Double,
                              now: Date, state st: inout FanState) -> Double? {
        let pts = Self.normalized(points)
        guard !pts.isEmpty else { return nil }
        guard let t = smoothed(sensor, temps, dt: dt, rise: smoothing.riseTau, fall: smoothing.fallTau) else { return inputMissing(sensor, st) }
        let up = Self.interpolate(pts, t)
        let down = Self.interpolate(pts, t + hyst)        // only go down once temp fell by `hyst`
        let current = st.percent
        return evaluateCurve(below, points: pts, t: t, up: up, down: down, current: current,
                             hyst: hyst, slewCfg: slewCfg, dt: dt, now: now, state: &st)
    }

    private func evaluateCurve(_ below: BelowFirstPoint, points: [CurvePoint], t: Double, up: Double, down: Double,
                               current: Double?, hyst: Double, slewCfg: Slew, dt: Double, now: Date,
                               state st: inout FanState) -> Double? {
        switch below {
        case .system:
            return releasingCurvePercent(points: points, t: t, up: up, down: down, current: current, hyst: hyst, slewCfg: slewCfg, dt: dt, now: now, state: &st)
        case .stop where profile.scheme.allowsFanStop:
            return stoppingCurvePercent(points: points, t: t, up: up, down: down, current: current, hyst: hyst, slewCfg: slewCfg, dt: dt, now: now, state: &st)
        case .stop, .minimum:
            return trackingCurvePercent(up: up, down: down, current: current, slewCfg: slewCfg, dt: dt, now: now, state: &st)
        }
    }

    /// Engage at the first point and release below first − hysteresis, preventing System ↔ manual flapping.
    private func releasingCurvePercent(points: [CurvePoint], t: Double, up: Double, down: Double, current: Double?,
                                       hyst: Double, slewCfg: Slew, dt: Double, now: Date, state st: inout FanState) -> Double? {
        if current == nil, t < points[0].celsius { return nil }
        if t + hyst < points[0].celsius, (current ?? 0) <= points[0].percent + 0.01 {
            st.lastDemandAboveAt = nil
            return nil                                    // quiet idle: let macOS stop the fans
        }
        return trackingCurvePercent(up: up, down: down, current: current, slewCfg: slewCfg, dt: dt, now: now, state: &st)
    }

    /// Stop below the first point with the same hysteresis band and restart directly at the curve's speed.
    private func stoppingCurvePercent(points: [CurvePoint], t: Double, up: Double, down: Double, current: Double?,
                                      hyst: Double, slewCfg: Slew, dt: Double, now: Date, state st: inout FanState) -> Double? {
        if current == nil { return initialStoppingCurvePercent(points: points, t: t, up: up, hyst: hyst, state: &st) }
        if current == Self.stoppedPercent { return restartStoppedCurvePercent(points: points, t: t, up: up, now: now, state: &st) }
        if t + hyst < points[0].celsius, (current ?? 0) <= points[0].percent + 0.01 {
            st.lastDemandAboveAt = nil
            return Self.stoppedPercent
        }
        return trackingCurvePercent(up: up, down: down, current: current, slewCfg: slewCfg, dt: dt, now: now, state: &st)
    }

    private func initialStoppingCurvePercent(points: [CurvePoint], t: Double, up: Double, hyst: Double,
                                             state st: inout FanState) -> Double {
        if t < points[0].celsius { return stopCurveAtFirstPoint(state: &st) }
        if t + hyst < points[0].celsius, 0 <= points[0].percent + 0.01 {
            return stopCurveAtFirstPoint(state: &st)
        }
        return up
    }

    private func restartStoppedCurvePercent(points: [CurvePoint], t: Double, up: Double, now: Date,
                                            state st: inout FanState) -> Double {
        if t < points[0].celsius { return stopCurveAtFirstPoint(state: &st) }
        st.lastDemandAboveAt = now
        return up
    }

    private func stopCurveAtFirstPoint(state st: inout FanState) -> Double {
        st.lastDemandAboveAt = nil
        return Self.stoppedPercent
    }

    private func trackingCurvePercent(up: Double, down: Double, current: Double?, slewCfg: Slew,
                                      dt: Double, now: Date, state st: inout FanState) -> Double {
        guard let cur = current else { return up }        // first sample: jump directly
        if up > cur {
            st.lastDemandAboveAt = now
            return slew(from: cur, to: up, dt: dt, up: slewCfg.upPercentPerSecond, down: slewCfg.downPercentPerSecond)
        }
        if down < cur {
            return decreasingCurvePercent(cur, down: down, slewCfg: slewCfg, dt: dt, now: now, state: st)
        }
        st.lastDemandAboveAt = now
        return cur
    }

    private func decreasingCurvePercent(_ cur: Double, down: Double, slewCfg: Slew, dt: Double,
                                        now: Date, state st: FanState) -> Double {
        if let since = st.lastDemandAboveAt, now.timeIntervalSince(since) < slewCfg.downHoldSeconds { return cur }
        return slew(from: cur, to: down, dt: dt, up: slewCfg.upPercentPerSecond, down: slewCfg.downPercentPerSecond)
    }

    private static func stopsBelowFirstPoint(_ s: FanStrategy) -> Bool {
        if case let .curve(_, _, _, below, _, _) = s { return below == .stop }
        return false
    }

    /// Sensor vanished: hold the current forced speed but never below 50 %, or stay System.
    private func failSafe(_ st: FanState) -> Double? { st.percent.map { max($0, 50) } }

    /// No value for `src`: a gated (idle) sensor that has no previous value holds the current speed; anything else
    /// is a lost sensor (fail-safe).
    private func inputMissing(_ src: TemperatureSource, _ st: FanState) -> Double? {
        gatedInputs.contains(src) ? st.percent : failSafe(st)
    }

    /// Fixed speeds ramp linearly from 0 % at (critical − 10 °C) to 100 % at critical.
    private func applyFixedFloor(_ p: Double, plan: FanPlan) -> Double {
        guard plan.safety.fixedModeFloor, let t = safetyEMA else { return p }
        let c = plan.safety.criticalC
        let floor = min(max((t - (c - 10)) / 10, 0), 1) * 100
        return max(p, floor)
    }

    private func smoothed(_ src: TemperatureSource, _ temps: [TemperatureSource: Double], dt: Double,
                          rise: Double, fall: Double) -> Double? {
        let key = EMAKey(source: src, rise: rise, fall: fall)
        if usedThisTick.contains(key) { return ema[key] }       // second fan on the same input this tick
        guard let raw = temps[src], raw.isFinite else {
            return heldSmoothedValue(key, source: src)
        }
        let v = smooth(previous: ema[key], raw: raw, dt: dt, rise: rise, fall: fall)
        ema[key] = v
        usedThisTick.insert(key)
        return v
    }

    /// Power-gated idle clusters keep their last value; truly missing inputs return nil for the fail-safe.
    private func heldSmoothedValue(_ key: EMAKey, source: TemperatureSource) -> Double? {
        guard gatedInputs.contains(source), let held = ema[key] else { return nil }
        usedThisTick.insert(key)
        return held
    }

    private func smooth(previous: Double?, raw: Double, dt: Double, rise: Double, fall: Double) -> Double {
        guard let prev = previous else { return raw }
        let tau = raw > prev ? rise : fall
        let alpha = tau <= 0 ? 1 : 1 - exp(-dt / tau)
        return prev + alpha * (raw - prev)
    }

    private func slew(from: Double, to: Double, dt: Double, up: Double, down: Double) -> Double {
        if to > from { return min(to, from + up * dt) }
        return max(to, from - down * dt)
    }

    // MARK: Curve helpers (public for the editor UI)

    /// Sorted by °C, percent clamped 0…100 and made non-decreasing (used by the curve editor too).
    public static func normalized(_ pts: [CurvePoint]) -> [CurvePoint] {
        var out: [CurvePoint] = []
        for p in pts.filter({ $0.celsius.isFinite && $0.percent.isFinite }).sorted(by: { $0.celsius < $1.celsius }) {
            var q = p
            q.percent = min(max(q.percent, out.last?.percent ?? 0), 100)
            if let last = out.last, last.celsius == q.celsius { out[out.count - 1] = q } else { out.append(q) }
        }
        return out
    }

    /// Piecewise-linear interpolation over normalized points; flat outside the first/last point.
    public static func interpolate(_ pts: [CurvePoint], _ t: Double) -> Double {
        guard let first = pts.first, let last = pts.last else { return 0 }
        if t <= first.celsius { return first.percent }
        if t >= last.celsius { return last.percent }
        for i in 1..<pts.count where t <= pts[i].celsius {
            let a = pts[i - 1], b = pts[i]
            let f = (t - a.celsius) / max(b.celsius - a.celsius, 1e-9)
            return a.percent + f * (b.percent - a.percent)
        }
        return last.percent
    }
}

/// Builds the engine plan from the user's config for the current power source (SPEC §2.9.2 table).
public enum FanPlanBuilder {
    public static func plan(config: FanUserConfig, power: PowerSourceKind, profile: FanHardwareProfile) -> FanPlan {
        var plan = basePlan(config: config)
        guard profile.isControllable else { return plan }            // fanless / unknown layout: System only
        switch config.mode {
        case .system: plan.shared = .system
        case .max: plan.shared = .fixedPercent(100)
        case .fixed: applyFixed(config: config, profile: profile, to: &plan)
        case .curve: plan.shared = selectedCurve(config: config, power: power).strategy   // always linked in v1
        }
        return plan
    }

    private static func basePlan(config: FanUserConfig) -> FanPlan {
        var plan = FanPlan()
        plan.safety = config.safety
        plan.thermalGuard = config.thermalGuard
        return plan
    }

    private static func applyFixed(config: FanUserConfig, profile: FanHardwareProfile, to plan: inout FanPlan) {
        if config.linked {
            plan.shared = .fixedPercent(percent(config.fixedPercent))
            return
        }
        plan.linked = false
        for fan in profile.fans {
            let value = config.fixedPercentPerFan[fan.index] ?? config.fixedPercent
            plan.perFan[fan.index] = .fixedPercent(percent(value))
        }
    }

    private static func percent(_ p: Double) -> Double {
        p.isFinite ? min(max(p, 0), 100) : 50
    }

    private static func selectedCurve(config: FanUserConfig, power: PowerSourceKind) -> FanCurve {
        power == .battery ? (config.curveBattery ?? config.curveAC) : config.curveAC
    }
}
