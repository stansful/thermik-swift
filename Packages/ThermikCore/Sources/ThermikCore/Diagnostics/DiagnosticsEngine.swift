// DiagnosticsEngine.swift — Thermik (MIT). Free hardware diagnostics. Pure value type, mutated on the main actor.
//
// `observe` is fed every tick (cheap: one pass over the fans and the sensors of the frame) and keeps only timers and
// a sparse 30 s sample per sensor; `items` turns that history plus the slow context into structured findings
// (no UI strings: the app localizes `DiagnosticFinding`). `report` renders Markdown for GitHub issues in English and
// redacts anything that looks like a serial number, UUID, MAC address, user name or host name.
//
// Rules (SPEC §2.13):
//   fans     stalled: < 100 rpm while it should spin (Thermik commands ≥ Mn, or the live target is ≥ Mn) for > 30 s.
//            A fan macOS stopped (target 0, "off by macOS") is fine. Not reaching target: |actual − target| > 25 %
//            for > 60 s. Either → warning; fanless → info.
//   sensors  suspect when a valid value stays exactly constant for > 10 min while a sibling of the same hardware
//            group changed by ≥ 2 °C, the raw value is out of the plausible range for > 1 min, or the sensor is
//            invalid for > 1 min while ≥ 80 % of its group is valid (power-gated clusters excluded).
//   foreign  fan modes forced (Ftst = 1, a mode key = 1 or FS! ≠ 0) for > 10 s while Thermik commands
//            nothing → another app controls the fans (reported through the helper item).
import Foundation
import ThermikSMC

public struct DiagnosticsEngine: Sendable {
    // MARK: Thresholds

    public static let stallSeconds: TimeInterval = 30
    public static let stoppedRPM = 100.0
    public static let mismatchSeconds: TimeInterval = 60
    public static let mismatchFraction = 0.25
    public static let stuckSeconds: TimeInterval = 600
    public static let siblingChangeC = 2.0
    public static let outOfRangeSeconds: TimeInterval = 60
    public static let invalidSeconds: TimeInterval = 60
    public static let invalidGroupValidFraction = 0.8
    public static let foreignControlSeconds: TimeInterval = 10
    /// Frames further apart than this (sleep, stalled loop) restart every timer: nobody observed the gap.
    public static let maxGap: TimeInterval = 180
    /// A sensor not seen for this long (not requested this cadence) restarts its tracking. The limit grows with the
    /// cadence (`unseenLimit`): at a 30 s or 60 s update interval every frame is that far apart.
    static let sensorUnseenReset: TimeInterval = 30
    /// A sensor missing from the frames for longer than this many frame spacings restarts its tracking.
    static let sensorUnseenFrames = 1.5
    static let sampleSpacing: TimeInterval = 30
    static let sampleHistory: TimeInterval = 15 * 60

    // MARK: State

    private struct FanTrack: Sendable {
        var stallSince: Date?
        var mismatchSince: Date?
        var last: FanSnapshot?
        var expectedRPM: Double?            // what it should run at; nil = macOS may keep it off
        var commandedByThermik = false
    }

    private struct Point: Sendable { var t: Date; var v: Double }

    private struct SensorTrack: Sendable {
        var lastSeen: Date?
        var lastValue: Double?
        var constantSince: Date?            // the valid value has been exactly `lastValue` since then
        var outOfRangeSince: Date?
        var lastRaw: Double?
        var invalidSince: Date?
        var samples: [Point] = []           // one valid value every ~30 s, last 15 min

        mutating func observeValid(_ v: Double, now: Date) {
            invalidSince = nil
            if lastValue != v { lastValue = v; constantSince = now } else if constantSince == nil { constantSince = now }
            if samples.last.map({ now.timeIntervalSince($0.t) >= DiagnosticsEngine.sampleSpacing }) ?? true {
                samples.append(Point(t: now, v: v))
                let horizon = now.addingTimeInterval(-DiagnosticsEngine.sampleHistory)
                if let first = samples.firstIndex(where: { $0.t >= horizon }), first > 0 { samples.removeFirst(first) }
            }
        }
    }

    /// One visible-by-default sensor of the inventory (hidden families are not judged). Index-based storage keeps
    /// every per-tick update in place (no dictionary copy-on-write of the sample arrays).
    private struct SensorSlot: Sendable {
        let id: SensorID
        let group: SensorGroup
        var track = SensorTrack()
    }

    private var profile: FanHardwareProfile = .none
    private var fanTracks: [Int: FanTrack] = [:]
    private var lastFanState: FanControlState?
    private var foreignSince: Date?
    private var lastFrameDate: Date?
    private var slots: [SensorSlot] = []
    private var siblings: [SensorGroup: [Int]] = [:]     // slot indices per hardware group
    private var groupValidFraction: [SensorGroup: Double] = [:]
    private var lastValidCount = 0

    /// product name for a suspected foreign fan controller (set by the store / probe from
    /// FanStore's naming or `installedFanControlProducts()`); nil = unnamed.
    public var foreignControllerName: String?
    /// the nominal sampling interval (s), set by the store before every `observe` (0 = unknown: the spacing of
    /// the frames alone sets the sensor-unseen limit).
    public var nominalInterval: TimeInterval = 0

    public init() {}

    // MARK: Observation

    /// sensor groups and default visibility for the sensor checks (call after discovery).
    public mutating func load(inventory: SensorInventory) {
        let old = Dictionary(slots.map { ($0.id, $0.track) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<SensorID>()
        slots = inventory.sensors.filter { $0.isVisibleByDefault && seen.insert($0.id).inserted }
            .map { SensorSlot(id: $0.id, group: $0.group, track: old[$0.id] ?? SensorTrack()) }
        siblings = Dictionary(grouping: slots.indices, by: { slots[$0].group })
        if !inventory.fanProfile.fans.isEmpty { profile = inventory.fanProfile }
    }

    /// Feed every tick: tracks fan stall / target mismatch and stuck / out-of-range sensors over time.
    public mutating func observe(frame: SensorFrame, commands: [Int: FanCommand], profile: FanHardwareProfile) {
        let now = frame.date
        let spacing = lastFrameDate.map { now.timeIntervalSince($0) } ?? 0
        if let last = lastFrameDate, now.timeIntervalSince(last) > Self.maxGap || now < last { restartTimers() }
        lastFrameDate = now
        if !profile.fans.isEmpty || self.profile.fans.isEmpty { self.profile = profile }
        if let state = frame.fans { observeFans(state, commands: commands, now: now) }
        // P-core values are forced invalid right after wake.
        if !frame.isPostWake { observeSensors(frame, now: now, unseenLimit: unseenLimit(frameSpacing: spacing)) }
    }

    /// How long a sensor may be missing before its tracking restarts: 30 s, or 1.5 frame spacings at a slower cadence
    /// (the nominal interval or this frame's spacing, whichever is longer), so a sensor read every 60 s tick keeps its
    /// timers while one that skipped a frame starts over.
    private func unseenLimit(frameSpacing: TimeInterval) -> TimeInterval {
        max(Self.sensorUnseenReset, Self.sensorUnseenFrames * max(nominalInterval, frameSpacing))
    }

    private mutating func restartTimers() {
        for k in fanTracks.keys { fanTracks[k]?.stallSince = nil; fanTracks[k]?.mismatchSince = nil }
        foreignSince = nil
        for i in slots.indices { slots[i].track = SensorTrack() }
    }

    private mutating func observeFans(_ state: FanControlState, commands: [Int: FanCommand], now: Date) {
        lastFanState = state
        observeForeignControl(state, commands: commands, now: now)
        for snap in state.fans { observeFan(snap, command: commands[snap.index], now: now) }
    }

    private mutating func observeForeignControl(_ state: FanControlState, commands: [Int: FanCommand], now: Date) {
        let thermikControls = commands.values.contains { if case .rpm = $0 { return true } else { return false } }
        guard state.anyManual && !thermikControls else { foreignSince = nil; return }
        foreignSince = foreignSince ?? now
    }

    private mutating func observeFan(_ snap: FanSnapshot, command: FanCommand?, now: Date) {
        guard let fan = profile.fan(snap.index) else { return }
        var track = fanTracks[snap.index] ?? FanTrack()
        let floor = fan.minRPM * 0.95
        updateExpectation(&track, command: command, snap: snap, floor: floor)
        updateStall(&track, snap: snap, floor: floor, now: now)
        updateMismatch(&track, snap: snap, now: now)
        track.last = snap
        fanTracks[snap.index] = track
    }

    private func updateExpectation(_ track: inout FanTrack, command: FanCommand?, snap: FanSnapshot, floor: Double) {
        switch command {
        case .rpm(let rpm)?:
            // A stop request may be held at the minimum by the helper (hot die): check against the live target then.
            track.expectedRPM = rpm == 0 && snap.targetRPM >= floor ? snap.targetRPM : rpm
            track.commandedByThermik = true
        case .system?, nil:
            // macOS (or another app) decides: it must spin only when its own target asks for it.
            track.expectedRPM = snap.targetRPM >= floor ? snap.targetRPM : nil
            track.commandedByThermik = false
        }
    }

    private func updateStall(_ track: inout FanTrack, snap: FanSnapshot, floor: Double, now: Date) {
        let stopped = snap.actualRPM < Self.stoppedRPM
        guard let expected = track.expectedRPM, expected >= floor, stopped else { track.stallSince = nil; return }
        track.stallSince = track.stallSince ?? now
    }

    private func updateMismatch(_ track: inout FanTrack, snap: FanSnapshot, now: Date) {
        let stopped = snap.actualRPM < Self.stoppedRPM
        guard let expected = track.expectedRPM, expected > 0, !stopped,
              abs(snap.actualRPM - expected) > expected * Self.mismatchFraction else { track.mismatchSince = nil; return }
        track.mismatchSince = track.mismatchSince ?? now
    }

    private mutating func observeSensors(_ frame: SensorFrame, now: Date, unseenLimit: TimeInterval) {
        guard !slots.isEmpty else { return }
        var valid: [SensorGroup: Int] = [:], read: [SensorGroup: Int] = [:]
        var validCount = 0
        for i in slots.indices {
            observeSensor(at: i, frame: frame, now: now, unseenLimit: unseenLimit,
                          valid: &valid, read: &read, validCount: &validCount)
        }
        groupValidFraction = read.reduce(into: [:]) { $0[$1.key] = Double(valid[$1.key] ?? 0) / Double(max($1.value, 1)) }
        lastValidCount = validCount
    }

    private mutating func observeSensor(at index: Int, frame: SensorFrame, now: Date, unseenLimit: TimeInterval,
                                        valid: inout [SensorGroup: Int], read: inout [SensorGroup: Int], validCount: inout Int) {
        resetSensorIfUnseen(at: index, now: now, unseenLimit: unseenLimit)
        let id = slots[index].id, group = slots[index].group
        let gated = frame.gated.contains(id)
        guard frame.values[id] != nil || frame.raw[id] != nil || gated else { return }       // not read this tick
        slots[index].track.lastSeen = now
        slots[index].track.lastRaw = frame.raw[id]
        if gated { resetGatedSensor(at: index); return }
        read[group, default: 0] += 1
        observeSensorValue(at: index, value: frame.values[id], group: group, now: now, valid: &valid, validCount: &validCount)
        observeOutOfRange(at: index, raw: frame.raw[id], now: now)
    }

    private mutating func resetSensorIfUnseen(at index: Int, now: Date, unseenLimit: TimeInterval) {
        guard let seen = slots[index].track.lastSeen, now.timeIntervalSince(seen) > unseenLimit else { return }
        slots[index].track = SensorTrack()
    }

    private mutating func resetGatedSensor(at index: Int) {
        // A power-gated cluster is not a fault: forget its timers.
        slots[index].track.lastValue = nil
        slots[index].track.constantSince = nil
        slots[index].track.invalidSince = nil
        slots[index].track.outOfRangeSince = nil
    }

    private mutating func observeSensorValue(at index: Int, value: Double?, group: SensorGroup, now: Date,
                                             valid: inout [SensorGroup: Int], validCount: inout Int) {
        guard let value else {
            slots[index].track.invalidSince = slots[index].track.invalidSince ?? now
            slots[index].track.lastValue = nil
            slots[index].track.constantSince = nil
            return
        }
        valid[group, default: 0] += 1
        validCount += 1
        slots[index].track.observeValid(value, now: now)
    }

    private mutating func observeOutOfRange(at index: Int, raw: Double?, now: Date) {
        let range = slots[index].group.plausibleRange
        guard let raw, raw.isFinite, !range.contains(raw) else {
            slots[index].track.outOfRangeSince = nil
            return
        }
        slots[index].track.outOfRangeSince = slots[index].track.outOfRangeSince ?? now
    }

    // MARK: Derived state

    /// Fans currently considered stalled (for the fanStalled alert).
    public var stalledFans: [Int] {
        guard let now = lastFrameDate else { return [] }
        return fanTracks.filter { $0.value.stallSince.map { now.timeIntervalSince($0) > Self.stallSeconds } ?? false }
            .map(\.key).sorted()
    }

    /// fans whose speed differs from the target by > 25 % for > 60 s (stalled fans excluded).
    public var fansNotReachingTarget: [Int] {
        guard let now = lastFrameDate else { return [] }
        return fanTracks.filter { $0.value.mismatchSince.map { now.timeIntervalSince($0) > Self.mismatchSeconds } ?? false }
            .map(\.key).sorted()
    }

    /// another process has been forcing the fans for > 10 s while Thermik commanded nothing.
    public var foreignControlSuspected: Bool {
        guard let now = lastFrameDate, let since = foreignSince else { return false }
        return now.timeIntervalSince(since) >= Self.foreignControlSeconds
    }

    /// suspect sensors with the reason, sorted by id.
    public func suspectSensors() -> [(id: SensorID, reason: String)] {
        guard let now = lastFrameDate else { return [] }
        let out = slots.indices.compactMap { suspectSensor(at: $0, now: now) }
        return out.sorted { $0.0 < $1.0 }.map { (id: $0.0, reason: $0.1) }
    }

    private func suspectSensor(at index: Int, now: Date) -> (SensorID, String)? {
        if let finding = outOfRangeFinding(at: index, now: now) { return finding }
        if let finding = invalidFinding(at: index, now: now) { return finding }
        return stuckFinding(at: index, now: now)
    }

    private func outOfRangeFinding(at index: Int, now: Date) -> (SensorID, String)? {
        let slot = slots[index], track = slot.track
        guard let since = track.outOfRangeSince, now.timeIntervalSince(since) > Self.outOfRangeSeconds,
              let raw = track.lastRaw else { return nil }
        let range = slot.group.plausibleRange
        return (slot.id, String(format: "out of range for %@: %.1f °C (plausible %.0f…%.0f °C)",
                                Self.duration(now.timeIntervalSince(since)), raw, range.lowerBound, range.upperBound))
    }

    private func invalidFinding(at index: Int, now: Date) -> (SensorID, String)? {
        let slot = slots[index], track = slot.track
        let fraction = groupValidFraction[slot.group] ?? 0
        guard let since = track.invalidSince, now.timeIntervalSince(since) > Self.invalidSeconds,
              fraction >= Self.invalidGroupValidFraction else { return nil }
        return (slot.id, String(format: "invalid for %@ while %.0f %% of its group (%@) is valid",
                                Self.duration(now.timeIntervalSince(since)), fraction * 100, slot.group.rawValue))
    }

    private func stuckFinding(at index: Int, now: Date) -> (SensorID, String)? {
        let slot = slots[index], track = slot.track
        guard let since = track.constantSince, let value = track.lastValue,
              now.timeIntervalSince(since) > Self.stuckSeconds,
              let change = siblingChange(of: index, since: since), change >= Self.siblingChangeC else { return nil }
        return (slot.id, String(format: "constant %.2f °C for %@ while a sibling changed by %.1f °C",
                                value, Self.duration(now.timeIntervalSince(since)), change))
    }

    /// max − min of the first visible sibling (same hardware group) that changed by ≥ 2 °C over [since, now], else the
    /// largest change seen (nil without sibling samples).
    private func siblingChange(of index: Int, since: Date) -> Double? {
        var best: Double?
        for sibling in siblings[slots[index].group] ?? [] where sibling != index {
            guard let change = sampleChange(of: sibling, since: since) else { continue }
            best = max(best ?? 0, change)
            if change >= Self.siblingChangeC { break }
        }
        return best
    }

    private func sampleChange(of index: Int, since: Date) -> Double? {
        var lo = Double.infinity, hi = -Double.infinity
        for point in slots[index].track.samples.reversed() {
            if point.t < since { break }
            lo = min(lo, point.v)
            hi = max(hi, point.v)
        }
        guard hi >= lo else { return nil }
        return hi - lo
    }

    // MARK: Items

    public func items(context: DiagnosticsContext, now: Date) -> [DiagnosticItem] {
        DiagnosticKind.allCases.map { kind in
            let evaluation = evaluation(for: kind, context: context)
            return DiagnosticItem(id: kind, status: evaluation.0, finding: evaluation.1,
                                  details: evaluation.2, updated: now)
        }
    }

    private func evaluation(for kind: DiagnosticKind, context: DiagnosticsContext) -> Evaluation {
        switch kind {
        case .lastShutdown: return lastShutdownItem(context)
        case .fans: return fansItem(context)
        case .sensors: return sensorsItem(context)
        case .battery: return batteryItem(context)
        case .thermal: return thermalItem(context)
        case .storage: return storageItem(context)
        case .helper: return helperItem(context)
        case .smc: return smcItem(context)
        }
    }

    private typealias Evaluation = (DiagnosticStatus, DiagnosticFinding, [DiagnosticDetail])

    private func lastShutdownItem(_ c: DiagnosticsContext) -> Evaluation {
        let boot = c.slow.boot
        let panic = !(boot?.panicLogPath ?? "").isEmpty
        var details = bootDetails(boot)
        guard let verdict = c.slow.shutdownVerdict ?? (panic ? .kernelPanic : nil) else {
            return (.unknown, boot == nil ? .unknown : .shutdown(.unknown, panicLog: false), details)
        }
        details.insert(DiagnosticDetail("Classification", Self.verdictName(verdict)), at: 0)
        return (shutdownStatus(verdict, panic: panic), .shutdown(panic ? .kernelPanic : verdict, panicLog: panic), details)
    }

    private func bootDetails(_ boot: BootHistory?) -> [DiagnosticDetail] {
        var details: [DiagnosticDetail] = []
        guard let boot else { return details }
        appendBootReasonDetails(&details, boot)
        appendBootTimingDetails(&details, boot)
        appendBootOtherDetails(&details, boot)
        return details
    }

    private func appendBootReasonDetails(_ details: inout [DiagnosticDetail], _ boot: BootHistory) {
        appendNonEmptyDetail(&details, "kern.shutdownreason", boot.shutdownReason)
        appendNonEmptyDetail(&details, "kern.bootreason", boot.bootReason)
        appendNonEmptyDetail(&details, "kern.wakereason", boot.wakeReason)
        appendNonEmptyDetail(&details, "Last sleep reason", boot.lastSleepReason)
        appendNonEmptyDetail(&details, "Wake type", boot.wakeType)
    }

    private func appendBootTimingDetails(_ details: inout [DiagnosticDetail], _ boot: BootHistory) {
        appendNonEmptyDetail(&details, "Boot time", boot.bootTime.map(Self.iso))
        appendNonEmptyDetail(&details, "Last sleep", boot.lastSleepTime.map(Self.iso))
        appendNonEmptyDetail(&details, "Last wake", boot.lastWakeTime.map(Self.iso))
    }

    private func appendBootOtherDetails(_ details: inout [DiagnosticDetail], _ boot: BootHistory) {
        appendNonEmptyDetail(&details, "Lid closed", boot.lidClosed.map { $0 ? "yes" : "no" })
        appendNonEmptyDetail(&details, "Previous shutdown cause (Intel)", boot.intelShutdownCause.map(String.init))
        appendNonEmptyDetail(&details, "Panic report", boot.panicLogPath)
    }

    private func appendNonEmptyDetail(_ details: inout [DiagnosticDetail], _ label: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        details.append(DiagnosticDetail(label, value))
    }

    private func shutdownStatus(_ verdict: ShutdownVerdict, panic: Bool) -> DiagnosticStatus {
        if panic || verdict == .kernelPanic { return .error }
        if verdict.isAbnormal { return .warning }
        if verdict == .unknown { return .unknown }
        if verdict == .other { return .info }
        return .ok
    }

    private func fansItem(_ c: DiagnosticsContext) -> Evaluation {
        let fanProfile = profile.fans.isEmpty ? (c.inventory?.fanProfile ?? .none) : profile
        guard !fanProfile.fans.isEmpty else { return fanlessItem(c) }
        let details = fanDetails(fanProfile)
        guard lastFanState != nil else { return (.unknown, .unknown, details) }
        let stalled = stalledFans
        let mismatch = fansNotReachingTarget.filter { !stalled.contains($0) }
        return fansEvaluation(profile: fanProfile, details: details, stalled: stalled, mismatch: mismatch)
    }

    private func fanlessItem(_ c: DiagnosticsContext) -> Evaluation {
        // No fans discovered: fanless only when discovery actually ran on a reachable SMC.
        if let inventory = c.inventory, inventory.smcAvailable { return (.info, .fanless, []) }
        return (.unknown, .unknown, [])
    }

    private func fanDetails(_ profile: FanHardwareProfile) -> [DiagnosticDetail] {
        var details = [DiagnosticDetail("Scheme", profile.scheme.description)]
        if let ftst = lastFanState?.ftst { details.append(DiagnosticDetail("Ftst", String(ftst))) }
        if let bits = lastFanState?.forceBits { details.append(DiagnosticDetail("FS!", String(format: "0x%04x", bits))) }
        for fan in profile.fans { details.append(fanDetail(fan)) }
        if foreignControlSuspected { details.append(DiagnosticDetail("Control", "another app is forcing the fans")) }
        return details
    }

    private func fanDetail(_ fan: FanDescriptor) -> DiagnosticDetail {
        let track = fanTracks[fan.index]
        var parts = [String(format: "range %.0f–%.0f rpm", fan.minRPM, fan.maxRPM)]
        if let snapshot = track?.last {
            parts.insert(String(format: "%.0f rpm, target %.0f rpm", snapshot.actualRPM, snapshot.targetRPM), at: 0)
            if let mode = snapshot.mode { parts.append("mode \(mode)") }
        }
        if track?.commandedByThermik == true, let expected = track?.expectedRPM {
            parts.append(String(format: "Thermik commands %.0f rpm", expected))
        }
        return DiagnosticDetail("Fan \(fan.index) (\(fan.name))", parts.joined(separator: ", "))
    }

    private func fansEvaluation(profile: FanHardwareProfile, details: [DiagnosticDetail],
                                stalled: [Int], mismatch: [Int]) -> Evaluation {
        var details = details
        if !stalled.isEmpty {
            if !mismatch.isEmpty { details.append(DiagnosticDetail("Not reaching target", mismatch.map(String.init).joined(separator: ", "))) }
            return (.warning, .fansStalled(stalled), details)
        }
        if !mismatch.isEmpty { return (.warning, .fansNotReachingTarget(mismatch), details) }
        return (.ok, .fansOK(count: profile.fans.count), details)
    }

    private func sensorsItem(_ c: DiagnosticsContext) -> Evaluation {
        guard let inv = c.inventory, !inv.sensors.isEmpty else { return (.unknown, .unknown, []) }
        let suspects = suspectSensors()
        var details = [DiagnosticDetail("Temperature sensors", String(inv.sensors.count)),
                       DiagnosticDetail("Valid in the last tick", String(lastValidCount))]
        details += suspects.map { DiagnosticDetail($0.id.description, $0.reason) }
        if !suspects.isEmpty { return (.warning, .sensorsSuspect(suspects.map(\.id)), details) }
        guard lastFrameDate != nil else { return (.unknown, .sensorsOK(count: inv.sensors.count), details) }
        return (.ok, .sensorsOK(count: inv.sensors.count), details)
    }

    private func batteryItem(_ c: DiagnosticsContext) -> Evaluation {
        let battery = c.battery
        let apple = c.slow.appleBatteryHealth
        guard battery != nil || apple != nil else { return (.info, .noBattery, []) }
        let condition = batteryCondition(battery, apple: apple)
        let health = apple?.maximumCapacityPercent.map(Double.init) ?? battery?.healthPercent
        let rated = battery?.designCycleCount
        let details = batteryDetails(battery, apple: apple)
        let finding = DiagnosticFinding.battery(condition, healthPercent: health,
                                                cycles: battery?.cycleCount, ratedCycles: rated)
        return (batteryStatus(condition, health: health), finding, details)
    }

    private func batteryCondition(_ battery: BatterySnapshot?, apple: AppleBatteryHealth?) -> BatteryCondition {
        var condition = apple?.condition ?? .unknown
        if let failure = battery?.permanentFailureStatus, failure != 0 { condition = .permanentFailure }
        else if condition == .unknown, battery != nil { condition = .normal }    // gauge readable, no failure flag
        return condition
    }

    private func batteryDetails(_ battery: BatterySnapshot?, apple: AppleBatteryHealth?) -> [DiagnosticDetail] {
        var details = appleBatteryDetails(apple)
        appendBatteryHealthDetails(&details, battery)
        appendBatteryStatusDetails(&details, battery)
        return details
    }

    private func appleBatteryDetails(_ apple: AppleBatteryHealth?) -> [DiagnosticDetail] {
        var details: [DiagnosticDetail] = []
        appendDetail(&details, "Condition (system_profiler)", apple?.conditionRaw)
        appendDetail(&details, "Maximum capacity (Apple)", apple?.maximumCapacityPercent.map { "\($0) %" })
        return details
    }

    private func appendBatteryHealthDetails(_ details: inout [DiagnosticDetail], _ battery: BatterySnapshot?) {
        let rated = battery?.designCycleCount
        appendDetail(&details, "Health (nominal / design)", battery?.healthPercent.map { String(format: "%.1f %%", $0) })
        appendDetail(&details, "Health (raw max / design)", battery?.rawHealthPercent.map { String(format: "%.1f %%", $0) })
        appendDetail(&details, "Cycle count", battery?.cycleCount.map { count in rated.map { "\(count) of \($0)" } ?? String(count) })
        appendDetail(&details, "Design capacity", battery?.designCapacity_mAh.map { "\($0) mAh" })
        appendDetail(&details, "Nominal charge capacity", battery?.nominalChargeCapacity_mAh.map { "\($0) mAh" })
        appendDetail(&details, "Raw max capacity", battery?.rawMaxCapacity_mAh.map { "\($0) mAh" })
    }

    private func appendBatteryStatusDetails(_ details: inout [DiagnosticDetail], _ battery: BatterySnapshot?) {
        appendDetail(&details, "Temperature", battery?.temperatureC.map { String(format: "%.1f °C", $0) })
        appendDetail(&details, "Permanent failure status", battery?.permanentFailureStatus.map { String(format: "0x%x", $0) })
        appendDetail(&details, "Not charging reason", battery?.notChargingReason.map { String(format: "0x%x", $0) })
        appendDetail(&details, "Adapter", battery?.adapter?.watts.map { "\($0) W" }) // watts only: names are accessory names
    }

    private func appendDetail(_ details: inout [DiagnosticDetail], _ label: String, _ value: String?) {
        guard let value else { return }
        details.append(DiagnosticDetail(label, value))
    }

    private func batteryStatus(_ condition: BatteryCondition, health: Double?) -> DiagnosticStatus {
        switch condition {
        case .permanentFailure, .serviceRecommended: return .warning
        case .normal, .unknown:
            if let health, health < 80 { return .info }
            return condition == .unknown ? .unknown : .ok
        }
    }

    private func thermalItem(_ c: DiagnosticsContext) -> Evaluation {
        let details = [DiagnosticDetail("Thermal pressure", Self.pressureName(c.pressure)),
                       DiagnosticDetail("Events today", String(c.pressureEventsToday))]
        let finding = DiagnosticFinding.thermal(c.pressure, eventsToday: c.pressureEventsToday)
        if c.pressure >= .heavy { return (.warning, finding, details) }
        if c.pressureEventsToday > 0 { return (.info, finding, details) }
        return (.ok, finding, details)
    }

    private func storageItem(_ c: DiagnosticsContext) -> Evaluation {
        guard let drives = c.slow.nvme, !drives.isEmpty else {
            return (.unknown, .storage(percentUsed: nil, temperatureC: nil, criticalWarning: false), [])
        }
        let details = drives.enumerated().map { storageDetail(index: $0.offset, drive: $0.element) }
        let worst = drives.max { storageSeverity($0) < storageSeverity($1) } ?? drives[0]
        return (storageSeverity(worst), .storage(percentUsed: worst.percentageUsed, temperatureC: worst.temperatureC,
                                                 criticalWarning: worst.criticalWarning != 0), details)
    }

    private func storageSeverity(_ drive: NVMeHealth) -> DiagnosticStatus {
        drive.criticalWarning != 0 ? .error : (drive.percentageUsed >= 90 ? .warning : .ok)
    }

    private func storageDetail(index: Int, drive: NVMeHealth) -> DiagnosticDetail {
        let name = [drive.bsdName, drive.model].compactMap { $0 }.joined(separator: " · ")
        var parts = storageParts(drive)
        if drive.criticalWarning != 0 { parts.insert(String(format: "CRITICAL WARNING 0x%02x", drive.criticalWarning), at: 0) }
        if let firmware = drive.firmware { parts.append("firmware \(firmware)") }
        return DiagnosticDetail(name.isEmpty ? "Drive \(index)" : name, parts.joined(separator: ", "))
    }

    private func storageParts(_ drive: NVMeHealth) -> [String] {
        let written = drive.dataWrittenBytes / 1e12
        return ["\(drive.percentageUsed) % used", "\(drive.temperatureC) °C",
                "spare \(drive.availableSparePercent) % (threshold \(drive.availableSpareThresholdPercent) %)",
                String(format: "%.1f TB written", written), "\(drive.powerOnHours) h powered on",
                "\(drive.unsafeShutdowns) unsafe shutdowns", "\(drive.mediaErrors) media errors"]
    }

    private func helperItem(_ c: DiagnosticsContext) -> Evaluation {
        let (health, thermikHelper) = resolvedHelper(c.helper)
        var details = [DiagnosticDetail("State", Self.helperName(health))]
        if let thermikHelper { details.append(DiagnosticDetail("Thermik helper", Self.helperName(thermikHelper))) }
        if case .foreignController = health, let ftst = lastFanState?.ftst { details.append(DiagnosticDetail("Ftst", String(ftst))) }
        return helperEvaluation(health, details: details)
    }

    private func resolvedHelper(_ health: HelperHealth) -> (HelperHealth, HelperHealth?) {
        guard foreignControlSuspected else { return (health, nil) }
        switch health {
        case .foreignController(let name):
            return (.foreignController(name ?? foreignControllerName), nil)
        case .notApplicable:
            return (health, nil)
        default:
            // Thermik's own helper behind a foreign controller.
            return (.foreignController(foreignControllerName), health)
        }
    }

    private func helperEvaluation(_ health: HelperHealth, details: [DiagnosticDetail]) -> Evaluation {
        var details = details
        switch health {
        case .ready: return (.ok, .helper(health), details)
        case .requiresApproval, .needsUpgrade, .foreignController: return (.warning, .helper(health), details)
        case .unreachable(let why):
            details.append(DiagnosticDetail("Reason", why))
            return (.warning, .helper(health), details)
        case .notInstalled, .notApplicable: return (.info, .helper(health), details)
        }
    }

    private func smcItem(_ c: DiagnosticsContext) -> Evaluation {
        guard let inventory = c.inventory else { return (.unknown, .unknown, []) }
        let finding = DiagnosticFinding.smc(available: inventory.smcAvailable, keyCount: inventory.smcKeyCount,
                                            catalog: inventory.catalogStatus)
        let details = smcDetails(inventory)
        guard inventory.smcAvailable else { return (.error, finding, details) }
        switch inventory.catalogStatus {
        case .verified: return (.ok, finding, details)
        case .unverified, .heuristic: return (.info, finding, details)
        }
    }

    private func smcDetails(_ inventory: SensorInventory) -> [DiagnosticDetail] {
        var details = smcIdentityDetails(inventory)
        details.append(DiagnosticDetail("Temperature sensors", String(inventory.sensors.count)))
        details.append(DiagnosticDetail("Heuristic sensor names", String(inventory.sensors.filter(\.isHeuristic).count)))
        return details
    }

    private func smcIdentityDetails(_ inventory: SensorInventory) -> [DiagnosticDetail] {
        let id = inventory.identity
        var details = [DiagnosticDetail("SMC keys", String(inventory.smcKeyCount)),
                       DiagnosticDetail("Catalog", Self.catalogName(inventory.catalogStatus)),
                       DiagnosticDetail("Platform", id.platformName),
                       DiagnosticDetail("Chip", id.chipName),
                       DiagnosticDetail("Model", id.modelIdentifier)]
        if let target = id.targetType { details.append(DiagnosticDetail("Target type", target)) }
        if let platform = id.smcPlatform { details.append(DiagnosticDetail("SMC platform (RPlt)", platform)) }
        return details
    }

    // MARK: Report

    /// Markdown report for GitHub issues. NEVER includes serial numbers, UUIDs or accessory names.
    public func report(items: [DiagnosticItem], machine: MachineInfo?, inventory: SensorInventory?, appVersion: String) -> String {
        var md = "## Thermik diagnostics report\n\n"
        md += "| | |\n|---|---|\n"
        appendGeneralRows(&md, machine: machine, inventory: inventory, appVersion: appVersion)
        appendFanRows(&md, items: items, inventory: inventory)
        appendChecks(&md, items: items)
        appendDetails(&md, items: items)
        return Self.redact(md)
    }

    private func appendGeneralRows(_ md: inout String, machine: MachineInfo?, inventory: SensorInventory?, appVersion: String) {
        appendRow(&md, "Generated", Self.iso(Date()))
        appendRow(&md, "App", "Thermik \(appVersion)")
        appendRow(&md, "macOS", machine?.osVersion ?? ProcessInfo.processInfo.operatingSystemVersionString)
        appendRow(&md, "Model", machine.map { m in m.marketingName.map { "\(m.modelIdentifier) (\($0))" } ?? m.modelIdentifier }
            ?? inventory?.identity.modelIdentifier)
        appendRow(&md, "Chip", machine?.chip ?? inventory?.identity.chipName)
        if let machine { appendMachineRows(&md, machine: machine) }
        if let inventory { appendInventoryRows(&md, inventory: inventory) }
    }

    private func appendMachineRows(_ md: inout String, machine: MachineInfo) {
        appendRow(&md, "Memory", machine.memoryBytes > 0 ? "\(machine.memoryBytes >> 30) GB" : nil)
        appendRow(&md, "CPUs", machine.perfLevels.isEmpty ? String(machine.logicalCPUs)
            : machine.perfLevels.map { "\($0.logicalCPUs) \($0.name)" }.joined(separator: " + "))
        appendRow(&md, "GPU", machine.gpuName.map { name in machine.gpuCores.map { "\(name), \($0) cores" } ?? name })
        appendRow(&md, "Rosetta", machine.isTranslated ? "yes" : nil)
    }

    private func appendInventoryRows(_ md: inout String, inventory: SensorInventory) {
        appendRow(&md, "Sensor catalog", Self.catalogName(inventory.catalogStatus))
        appendRow(&md, "SMC", inventory.smcAvailable ? "\(inventory.smcKeyCount) keys" : "unavailable")
        appendRow(&md, "Temperature sensors", String(inventory.sensors.count))
    }

    private func appendFanRows(_ md: inout String, items: [DiagnosticItem], inventory: SensorInventory?) {
        let fanProfile = profile.fans.isEmpty ? (inventory?.fanProfile ?? .none) : profile
        appendRow(&md, "Fan scheme", fanProfile.scheme.description)
        appendRow(&md, "Fans", fanProfile.fans.isEmpty ? "none"
            : fanProfile.fans.map { String(format: "%d: %.0f–%.0f rpm", $0.index, $0.minRPM, $0.maxRPM) }.joined(separator: "; "))
        if let item = items.first(where: { $0.id == .helper }), case .helper(let health) = item.finding {
            appendRow(&md, "Helper", Self.helperName(health))
        }
    }

    private func appendChecks(_ md: inout String, items: [DiagnosticItem]) {
        md += "\n### Checks\n\n| Check | Status | Result |\n|---|---|---|\n"
        for item in items {
            md += "| \(item.id.rawValue) | \(Self.statusName(item.status)) | \(Self.cell(Self.summary(item.finding))) |\n"
        }
    }

    private func appendDetails(_ md: inout String, items: [DiagnosticItem]) {
        md += "\n### Details\n"
        for item in items where !item.details.isEmpty {
            md += "\n**\(item.id.rawValue)** (\(Self.statusName(item.status)))\n\n"
            for detail in item.details { md += "- \(detail.label): `\(detail.value.replacingOccurrences(of: "`", with: "'"))`\n" }
        }
    }

    private func appendRow(_ md: inout String, _ key: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        md += "| \(key) | \(Self.cell(value)) |\n"
    }

    /// The "Recent events" Markdown section (newest last), redacted. DiagnosticsStore appends it to `report(…)`.
    public static func eventsMarkdown(_ events: [AppEvent], limit: Int = 50) -> String {
        var md = "\n### Recent events\n\n"
        let recent = events.suffix(limit)
        if recent.isEmpty { return md + "_none_\n" }
        md += "```\n"
        for e in recent { md += "\(iso(e.date))  \(e.payload.csvToken)\n" }
        md += "```\n"
        return redact(md)
    }

    /// removes identifying strings: 10–12 character upper-case alphanumerics that mix letters and
    /// digits (Apple serial numbers), UUIDs, MAC / Bluetooth addresses, the user's home path and the host name.
    public static func redact(_ text: String) -> String {
        var s = redactingHome(text)
        for (pattern, template) in redactionRules() {
            s = applyRedaction(pattern, template: template, to: s)
        }
        if let host = hostName(), host.count >= 3 { s = s.replacingOccurrences(of: host, with: "[host]") }
        return s
    }

    private static func redactingHome(_ text: String) -> String {
        let home = NSHomeDirectory()
        guard home.count > 1 else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    private static func redactionRules() -> [(String, String)] {
        return [
            (#"/Users/[^/\s`|]+"#, "/Users/[user]"),
            (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "[uuid]"),
            (#"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#, "[mac-address]"),
            (#"(?<![A-Za-z0-9])(?=[A-Z0-9]{10,12}(?![A-Za-z0-9]))(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10,12}"#, "[serial]"),
        ]
    }

    private static func applyRedaction(_ pattern: String, template: String, to text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func hostName() -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return nil }
        let name = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let short = name.split(separator: ".").first.map(String.init) ?? name
        return short.isEmpty || short == "localhost" ? nil : short
    }

    // MARK: Known fan controllers (naming only)

    /// launchd labels of known fan-control helpers (public identifiers). Only the PRESENCE of their
    /// plist / executable is checked; nothing is opened or read. Detection itself is the SMC state
    /// (`foreignControlSuspected`); these only put a name on it.
    public static let knownFanControlHelpers: [(label: String, product: String)] = [
        ("com.tunabellysoftware.TGFanHelper", "TG Pro"),
        ("com.crystalidea.macsfancontrol.smcwrite", "Macs Fan Control"),
        ("eu.exelban.Stats.SMC.Helper", "Stats"),
    ]

    /// SMC clients that are NOT fan controllers although they run a root helper that opens the SMC
    /// (battery charge limiters such as AlDente). Never reported as a fan controller.
    public static let knownNonFanSMCClients = ["aldente"]

    /// products of `knownFanControlHelpers` installed on this Mac (launchd plist or helper present).
    public static func installedFanControlProducts() -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for h in knownFanControlHelpers where !out.contains(h.product) {
            if fm.fileExists(atPath: "/Library/LaunchDaemons/\(h.label).plist")
                || fm.fileExists(atPath: "/Library/PrivilegedHelperTools/\(h.label)") {
                out.append(h.product)
            }
        }
        return out
    }

    /// false for names of known non-fan SMC clients (AlDente's helper and the like).
    public static func isPlausibleFanController(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !knownNonFanSMCClients.contains { lower.contains($0) }
    }

    // MARK: English names (report and details only; the app localizes findings itself)

    public static func summary(_ f: DiagnosticFinding) -> String {
        switch f {
        case .fansOK, .fanless, .fansStalled, .fansNotReachingTarget, .sensorsOK, .sensorsSuspect:
            return hardwareSummary(f)
        case .battery(let condition, let health, let cycles, let rated):
            return batterySummary(condition, health: health, cycles: cycles, rated: rated)
        case .storage(let used, let temperature, let critical):
            return storageSummary(used: used, temperature: temperature, critical: critical)
        case .shutdown, .noBattery, .thermal, .helper, .smc, .unknown:
            return generalSummary(f)
        }
    }

    private static func hardwareSummary(_ finding: DiagnosticFinding) -> String {
        switch finding {
        case .fansOK(let count): return "\(count) fan\(count == 1 ? "" : "s") OK"
        case .fanless: return "no fans (passively cooled)"
        case .fansStalled(let ids): return "stalled: fan " + ids.map(String.init).joined(separator: ", ")
        case .fansNotReachingTarget(let ids): return "not reaching target: fan " + ids.map(String.init).joined(separator: ", ")
        case .sensorsOK(let count): return "\(count) sensors, none suspect"
        case .sensorsSuspect(let ids): return "suspect: " + ids.map(\.description).joined(separator: ", ")
        default: return "no data"
        }
    }

    private static func batterySummary(_ condition: BatteryCondition, health: Double?, cycles: Int?, rated: Int?) -> String {
        var parts = [conditionName(condition)]
        if let health { parts.append(String(format: "health %.0f %%", health)) }
        if let cycles { parts.append(rated.map { "\(cycles) of \($0) cycles" } ?? "\(cycles) cycles") }
        return parts.joined(separator: ", ")
    }

    private static func storageSummary(used: Int?, temperature: Int?, critical: Bool) -> String {
        guard used != nil || temperature != nil || critical else { return "no NVMe health data" }
        var parts: [String] = []
        if critical { parts.append("CRITICAL WARNING") }
        if let used { parts.append("\(used) % used") }
        if let temperature { parts.append("\(temperature) °C") }
        return parts.joined(separator: ", ")
    }

    private static func generalSummary(_ finding: DiagnosticFinding) -> String {
        switch finding {
        case .shutdown(let verdict, let panic): return verdictName(verdict) + (panic ? " (panic report present)" : "")
        case .noBattery: return "no battery"
        case .thermal(let pressure, let count): return "\(pressureName(pressure)), \(count) event\(count == 1 ? "" : "s") today"
        case .helper(let health): return helperName(health)
        case .smc(let available, let keys, let catalog): return available ? "\(keys) keys, \(catalogName(catalog)) catalog" : "SMC unavailable"
        default: return "no data"
        }
    }

    public static func verdictName(_ v: ShutdownVerdict) -> String {
        switch v {
        case .normalRestart, .normalShutdown, .forced, .thermal, .powerLoss, .watchdog, .kernelPanic:
            return standardVerdictName(v)
        case .intelCode(let code): return "shutdown cause code \(code)"
        case .other: return "other"
        case .unknown: return "unknown"
        }
    }

    private static func standardVerdictName(_ verdict: ShutdownVerdict) -> String {
        switch verdict {
        case .normalRestart: return "normal restart"
        case .normalShutdown: return "normal shutdown"
        case .forced: return "forced (power button)"
        case .thermal: return "overheating"
        case .powerLoss: return "power loss or empty battery"
        case .watchdog: return "watchdog reset"
        case .kernelPanic: return "kernel panic"
        default: return "unknown"
        }
    }

    public static func statusName(_ s: DiagnosticStatus) -> String {
        switch s { case .ok: "OK"; case .info: "Info"; case .unknown: "Unknown"; case .warning: "Warning"; case .error: "Error" }
    }

    public static func pressureName(_ p: ThermalPressure) -> String {
        switch p { case .nominal: "nominal"; case .moderate: "moderate"; case .heavy: "heavy"; case .trapping: "trapping"; case .sleeping: "sleeping" }
    }

    public static func conditionName(_ c: BatteryCondition) -> String {
        switch c {
        case .normal: "normal"; case .serviceRecommended: "service recommended"
        case .permanentFailure: "permanent failure"; case .unknown: "unknown condition"
        }
    }

    public static func catalogName(_ c: CatalogStatus) -> String {
        switch c {
        case .verified(let p): "verified (\(p))"
        case .unverified(let p): "unverified (\(p))"
        case .heuristic(let p): "heuristic (\(p))"
        }
    }

    public static func helperName(_ h: HelperHealth) -> String {
        switch h {
        case .ready(let v): "ready (\(v))"
        case .notInstalled: "not installed"
        case .requiresApproval: "needs approval in Login Items"
        case .needsUpgrade: "needs an update"
        case .unreachable(let why): "unreachable (\(why))"
        case .foreignController(let name): "another app controls the fans" + (name.map { " (\($0))" } ?? "")
        case .notApplicable: "not applicable (no fans)"
        }
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func duration(_ s: TimeInterval) -> String {
        s >= 120 ? String(format: "%.0f min", s / 60) : String(format: "%.0f s", s)
    }

    private static func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
}
