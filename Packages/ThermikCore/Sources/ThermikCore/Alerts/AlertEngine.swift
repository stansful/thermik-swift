// AlertEngine.swift — Thermik (MIT).
// Pure, stateful: duration ("for N s"), hysteresis re-arm and cooldown per rule (SPEC §2.10).
//
// One state machine per rule:
//   idle ──condition true──▶ pending(since) ──held ≥ forSeconds AND now ≥ lastRaised + cooldown──▶ raised  (emits .raised)
//   pending ──condition false──▶ idle (nothing emitted; a single sample above never raises)
//   raised ──temperature < threshold − hysteresis, or condition false (other subjects)──▶ idle  (emits .cleared)
// While pending and the cooldown has not elapsed, the rule stays pending and raises as soon as the cooldown ends
// (if the condition still holds), so "no second raise within cooldownSeconds" holds for every subject.
// One-shot subjects (abnormalShutdown, fanModeChanged) emit `.raised` only and never enter the raised state.
// Disabled, removed or edited rules reset their state (an edit re-arms the rule immediately, cooldown included).
//
// `.anySensor` / `.group` use the hottest matching sensor (one state per rule, not per sensor): the event names
// the sensor that was hottest when it fired. A gap between evaluations longer than `maxGap` (sleep, a stalled
// loop) restarts pending timers, so a condition is never claimed to have "held" across time nobody observed.
import Foundation

public struct AlertEngine: Sendable {
    private enum Phase: Sendable, Equatable { case idle, pending, raised }

    private struct RuleState: Sendable {
        var phase: Phase = .idle
        var since: Date?                 // pending: when the condition became true
        var lastRaised: Date?            // cooldown reference
        var fingerprint: Fingerprint
    }

    /// The parameters whose change re-arms a rule (channels, sound and action do not affect the state machine).
    private struct Fingerprint: Sendable, Equatable {
        var subject: AlertRule.Subject
        var thresholdC: Double?
        var forSeconds: TimeInterval
        var hysteresisC: Double
        var cooldownSeconds: TimeInterval
        init(_ r: AlertRule) {
            subject = r.subject; thresholdC = r.thresholdC; forSeconds = r.forSeconds
            hysteresisC = r.hysteresisC; cooldownSeconds = r.cooldownSeconds
        }
    }

    /// What one subject looks like right now.
    private struct Reading {
        var active: Bool                 // the raise condition holds
        var value: Double?               // °C (temperature subjects)
        var sensorID: SensorID?
    }

    /// Evaluations further apart than this restart pending timers (the longest update interval is 60 s).
    public static let maxGap: TimeInterval = 180

    private var states: [UUID: RuleState] = [:]
    /// One-shot rules that already fired for this engine's lifetime (abnormalShutdown fires once per launch).
    private var firedOnce: Set<UUID> = []
    private var lastDate: Date?

    public init() {}

    /// rules currently in the raised state (AlertStore mirrors this into `activeRuleIDs`).
    public var raisedRuleIDs: Set<UUID> { Set(states.lazy.filter { $0.value.phase == .raised }.map(\.key)) }

    /// true once the one-shot rule `id` has fired (AlertStore stops passing the shutdown verdict).
    public func hasFired(_ id: UUID) -> Bool { firedOnce.contains(id) }

    public mutating func evaluate(rules: [AlertRule], inputs: AlertInputs) -> [AlertEvent] {
        let now = inputs.date
        // Sleep, a stalled loop or a clock jump: nobody observed the interval, so pending timers restart now.
        let restartPending = shouldRestartPending(at: now)
        lastDate = now
        removeDeletedRules(keeping: Set(rules.map(\.id)))
        var events: [AlertEvent] = []
        for rule in rules { evaluate(rule, inputs: inputs, now: now, restartPending: restartPending, events: &events) }
        return events
    }

    private mutating func shouldRestartPending(at now: Date) -> Bool {
        let gap = lastDate.map { now.timeIntervalSince($0) } ?? 0
        return gap > Self.maxGap || gap < 0
    }

    private mutating func removeDeletedRules(keeping ids: Set<UUID>) {
        states = states.filter { ids.contains($0.key) }
        firedOnce.formIntersection(ids)
    }

    private mutating func evaluate(_ rule: AlertRule, inputs: AlertInputs, now: Date,
                                   restartPending: Bool, events: inout [AlertEvent]) {
        guard rule.enabled else { states[rule.id] = nil; return }
        switch rule.subject {
        case .abnormalShutdown: evaluateAbnormalShutdown(rule, inputs: inputs, now: now, restartPending: restartPending, events: &events)
        case .fanModeChanged: evaluateFanModeChange(rule, inputs: inputs, now: now, restartPending: restartPending, events: &events)
        default: evaluateReading(rule, inputs: inputs, now: now, restartPending: restartPending, events: &events)
        }
    }

    private func currentState(for rule: AlertRule, now: Date, restartPending: Bool) -> RuleState {
        let fingerprint = Fingerprint(rule)
        var state = states[rule.id] ?? RuleState(fingerprint: fingerprint)
        if state.fingerprint != fingerprint { state = RuleState(fingerprint: fingerprint) }
        if restartPending, state.phase == .pending { state.since = now }
        return state
    }

    private mutating func evaluateAbnormalShutdown(_ rule: AlertRule, inputs: AlertInputs, now: Date,
                                                   restartPending: Bool, events: inout [AlertEvent]) {
        var state = currentState(for: rule, now: now, restartPending: restartPending)
        if inputs.abnormalShutdown != nil, !firedOnce.contains(rule.id) {
            firedOnce.insert(rule.id)
            state.lastRaised = now
            events.append(AlertEvent(ruleID: rule.id, date: now, kind: .raised, subject: rule.subject, value: nil, sensorID: nil))
        }
        states[rule.id] = state
    }

    private mutating func evaluateFanModeChange(_ rule: AlertRule, inputs: AlertInputs, now: Date,
                                                restartPending: Bool, events: inout [AlertEvent]) {
        var state = currentState(for: rule, now: now, restartPending: restartPending)
        if inputs.fanModeChange != nil, cooldownElapsed(state, rule, now) {
            state.lastRaised = now
            events.append(AlertEvent(ruleID: rule.id, date: now, kind: .raised, subject: rule.subject, value: nil, sensorID: nil))
        }
        states[rule.id] = state
    }

    private mutating func evaluateReading(_ rule: AlertRule, inputs: AlertInputs, now: Date,
                                          restartPending: Bool, events: inout [AlertEvent]) {
        var state = currentState(for: rule, now: now, restartPending: restartPending)
        guard let reading = Self.read(rule, inputs) else { states[rule.id] = nil; return }
        step(&state, rule: rule, reading: reading, now: now, events: &events)
        states[rule.id] = state
    }

    public mutating func reset() {
        states.removeAll()
        firedOnce.removeAll()
        lastDate = nil
    }

    // MARK: State machine

    private func step(_ s: inout RuleState, rule: AlertRule, reading: Reading, now: Date, events: inout [AlertEvent]) {
        switch s.phase {
        case .idle, .pending: stepWaiting(&s, rule: rule, reading: reading, now: now, events: &events)
        case .raised: stepRaised(&s, rule: rule, reading: reading, now: now, events: &events)
        }
    }

    private func stepWaiting(_ s: inout RuleState, rule: AlertRule, reading: Reading, now: Date, events: inout [AlertEvent]) {
        guard reading.active else { resetWaiting(&s); return }
        if s.phase == .idle { beginPending(&s, now: now) }
        let held = now.timeIntervalSince(s.since ?? now)
        guard held >= max(rule.forSeconds, 0), cooldownElapsed(s, rule, now) else { return }
        raise(&s, rule: rule, reading: reading, now: now, events: &events)
    }

    private func resetWaiting(_ s: inout RuleState) {
        s.phase = .idle
        s.since = nil
    }

    private func beginPending(_ s: inout RuleState, now: Date) {
        s.phase = .pending
        s.since = now
    }

    private func raise(_ s: inout RuleState, rule: AlertRule, reading: Reading, now: Date, events: inout [AlertEvent]) {
        s.phase = .raised
        s.since = nil
        s.lastRaised = now
        events.append(AlertEvent(ruleID: rule.id, date: now, kind: .raised, subject: rule.subject,
                                 value: reading.value, sensorID: reading.sensorID))
    }

    private func stepRaised(_ s: inout RuleState, rule: AlertRule, reading: Reading, now: Date, events: inout [AlertEvent]) {
        guard shouldClear(rule, reading: reading) else { return }
        s.phase = .idle
        events.append(AlertEvent(ruleID: rule.id, date: now, kind: .cleared, subject: rule.subject,
                                 value: reading.value, sensorID: reading.sensorID))
    }

    private func shouldClear(_ rule: AlertRule, reading: Reading) -> Bool {
        if rule.subject.isTemperature, let threshold = rule.thresholdC {
            // Re-arm only once the value fell clearly below the threshold. No value (sensor vanished) keeps it raised.
            return reading.value.map { $0 < threshold - max(rule.hysteresisC, 0) } ?? false
        }
        return !reading.active
    }

    private func cooldownElapsed(_ s: RuleState, _ rule: AlertRule, _ now: Date) -> Bool {
        guard let last = s.lastRaised else { return true }
        return now.timeIntervalSince(last) >= max(rule.cooldownSeconds, 0)
    }

    // MARK: Subjects

    /// nil = the rule cannot be evaluated (temperature subject without a threshold).
    private static func read(_ rule: AlertRule, _ inputs: AlertInputs) -> Reading? {
        switch rule.subject {
        case .anySensor, .aggregate, .group, .sensor:
            return readTemperature(rule, inputs)
        case .fanStalled, .thermalPressure, .batteryService:
            return readCondition(rule, inputs)
        case .abnormalShutdown, .fanModeChanged:
            return nil   // one-shot, handled in evaluate
        }
    }

    private static func readTemperature(_ rule: AlertRule, _ inputs: AlertInputs) -> Reading? {
        switch rule.subject {
        case .anySensor: return hottestReading(rule, inputs.sensorValues)
        case .aggregate(let kind): return temperature(rule, inputs.aggregates[kind], inputs.aggregates.sources[kind])
        case .group(let group):
            return hottestReading(rule, inputs.sensorValues.filter { inputs.sensorGroups[$0.key] == group })
        case .sensor(let id):
            // A rule that names a sensor keeps watching it after the user hid it (hidden values come separately).
            return temperature(rule, inputs.sensorValues[id] ?? inputs.namedSensorValues[id], id)
        default: return nil
        }
    }

    private static func readCondition(_ rule: AlertRule, _ inputs: AlertInputs) -> Reading? {
        switch rule.subject {
        case .fanStalled: return Reading(active: !inputs.stalledFans.isEmpty, value: nil, sensorID: nil)
        case .thermalPressure(let level): return Reading(active: inputs.pressure >= level, value: nil, sensorID: nil)
        case .batteryService: return Reading(active: inputs.batteryNeedsService, value: nil, sensorID: nil)
        default: return nil
        }
    }

    private static func hottestReading(_ rule: AlertRule, _ values: [SensorID: Double]) -> Reading? {
        let top = values.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }
        return temperature(rule, top?.value, top?.key)
    }

    private static func temperature(_ rule: AlertRule, _ value: Double?, _ id: SensorID?) -> Reading? {
        guard let threshold = rule.thresholdC, threshold.isFinite else { return nil }
        guard let v = value, v.isFinite else { return Reading(active: false, value: nil, sensorID: id) }
        return Reading(active: v > threshold, value: v, sensorID: id)
    }
}

/// stable machine name of a subject, e.g. "anySensor", "aggregate(cpuHottest)", "group(cpu)",
/// "sensor(smc:Tp01)", "thermalPressure(heavy)". Used by `AppEventPayload.csvToken` (CSV event column, SPEC §2.12)
/// and notification thread identifiers. Without it, string interpolation prints module-qualified associated
/// values ("aggregate(ThermikCore.AggregateKind.cpuHottest)").
extension AlertRule.Subject: CustomStringConvertible {
    public var description: String {
        switch self {
        case .anySensor: return "anySensor"
        case .aggregate(let k): return "aggregate(\(k.rawValue))"
        case .group(let g): return "group(\(g.rawValue))"
        case .sensor(let id): return "sensor(\(id.description))"
        case .fanStalled: return "fanStalled"
        case .fanModeChanged: return "fanModeChanged"
        case .thermalPressure(let p): return "thermalPressure(\(Self.name(p)))"
        case .abnormalShutdown: return "abnormalShutdown"
        case .batteryService: return "batteryService"
        }
    }

    private static func name(_ p: ThermalPressure) -> String {
        switch p {
        case .nominal: return "nominal"
        case .moderate: return "moderate"
        case .heavy: return "heavy"
        case .trapping: return "trapping"
        case .sleeping: return "sleeping"
        }
    }
}
