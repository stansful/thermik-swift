// DiagnosticsEngine.swift — Thermik (MIT). OWNER: Unit 6. API FROZEN (init / observe / stalledFans / items / report);
// additions are marked. Free hardware diagnostics (SPEC §2.13). Pure value type, mutated on the main actor.
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
//   foreign  (ADDED) fan modes forced (Ftst = 1, a mode key = 1 or FS! ≠ 0) for > 10 s while Thermik commands
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

    /// ADDED (Unit 6): product name for a suspected foreign fan controller (set by the store / probe from
    /// FanStore's naming or `installedFanControlProducts()`); nil = unnamed.
    public var foreignControllerName: String?
    /// ADDED: the nominal sampling interval (s), set by the store before every `observe` (0 = unknown: the spacing of
    /// the frames alone sets the sensor-unseen limit).
    public var nominalInterval: TimeInterval = 0

    public init() {}

    // MARK: Observation

    /// ADDED (Unit 6): sensor groups and default visibility for the sensor checks (call after discovery).
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
        let thermikControls = commands.values.contains { if case .rpm = $0 { return true } else { return false } }
        if state.anyManual && !thermikControls { foreignSince = foreignSince ?? now } else { foreignSince = nil }
        for snap in state.fans {
            guard let fan = profile.fan(snap.index) else { continue }
            var t = fanTracks[snap.index] ?? FanTrack()
            let floor = fan.minRPM * 0.95
            switch commands[snap.index] {
            case .rpm(let r)?:
                // A stop request may be held at the minimum by the helper (hot die): check against the live target then.
                t.expectedRPM = r == 0 && snap.targetRPM >= floor ? snap.targetRPM : r; t.commandedByThermik = true
            case .system?, nil:
                // macOS (or another app) decides: it must spin only when its own target asks for it.
                t.expectedRPM = snap.targetRPM >= floor ? snap.targetRPM : nil; t.commandedByThermik = false
            }
            let stopped = snap.actualRPM < Self.stoppedRPM
            if let e = t.expectedRPM, e >= floor, stopped { t.stallSince = t.stallSince ?? now } else { t.stallSince = nil }
            if let e = t.expectedRPM, e > 0, !stopped, abs(snap.actualRPM - e) > e * Self.mismatchFraction {
                t.mismatchSince = t.mismatchSince ?? now
            } else {
                t.mismatchSince = nil
            }
            t.last = snap
            fanTracks[snap.index] = t
        }
    }

    private mutating func observeSensors(_ frame: SensorFrame, now: Date, unseenLimit: TimeInterval) {
        guard !slots.isEmpty else { return }
        var valid: [SensorGroup: Int] = [:], read: [SensorGroup: Int] = [:]
        var validCount = 0
        for i in slots.indices {
            let id = slots[i].id, group = slots[i].group
            if let seen = slots[i].track.lastSeen, now.timeIntervalSince(seen) > unseenLimit { slots[i].track = SensorTrack() }
            let gated = frame.gated.contains(id)
            let raw = frame.raw[id]
            let value = frame.values[id]
            guard value != nil || raw != nil || gated else { continue }                     // not read this tick
            slots[i].track.lastSeen = now
            slots[i].track.lastRaw = raw
            if gated {
                // A power-gated cluster is not a fault: forget its timers.
                slots[i].track.lastValue = nil; slots[i].track.constantSince = nil
                slots[i].track.invalidSince = nil; slots[i].track.outOfRangeSince = nil
                continue
            }
            read[group, default: 0] += 1
            if let v = value {
                valid[group, default: 0] += 1
                validCount += 1
                slots[i].track.observeValid(v, now: now)
            } else {
                slots[i].track.invalidSince = slots[i].track.invalidSince ?? now
                slots[i].track.lastValue = nil; slots[i].track.constantSince = nil
            }
            if let r = raw, r.isFinite, !group.plausibleRange.contains(r) {
                slots[i].track.outOfRangeSince = slots[i].track.outOfRangeSince ?? now
            } else {
                slots[i].track.outOfRangeSince = nil
            }
        }
        groupValidFraction = read.reduce(into: [:]) { $0[$1.key] = Double(valid[$1.key] ?? 0) / Double(max($1.value, 1)) }
        lastValidCount = validCount
    }

    // MARK: Derived state

    /// Fans currently considered stalled (for the fanStalled alert).
    public var stalledFans: [Int] {
        guard let now = lastFrameDate else { return [] }
        return fanTracks.filter { $0.value.stallSince.map { now.timeIntervalSince($0) > Self.stallSeconds } ?? false }
            .map(\.key).sorted()
    }

    /// ADDED (Unit 6): fans whose speed differs from the target by > 25 % for > 60 s (stalled fans excluded).
    public var fansNotReachingTarget: [Int] {
        guard let now = lastFrameDate else { return [] }
        return fanTracks.filter { $0.value.mismatchSince.map { now.timeIntervalSince($0) > Self.mismatchSeconds } ?? false }
            .map(\.key).sorted()
    }

    /// ADDED (Unit 6): another process has been forcing the fans for > 10 s while Thermik commanded nothing.
    public var foreignControlSuspected: Bool {
        guard let now = lastFrameDate, let since = foreignSince else { return false }
        return now.timeIntervalSince(since) >= Self.foreignControlSeconds
    }

    /// ADDED (Unit 6): suspect sensors with the reason, sorted by id.
    public func suspectSensors() -> [(id: SensorID, reason: String)] {
        guard let now = lastFrameDate else { return [] }
        var out: [(SensorID, String)] = []
        for (i, slot) in slots.enumerated() {
            let id = slot.id, t = slot.track, group = slot.group
            if let since = t.outOfRangeSince, now.timeIntervalSince(since) > Self.outOfRangeSeconds, let r = t.lastRaw {
                let range = group.plausibleRange
                out.append((id, String(format: "out of range for %@: %.1f °C (plausible %.0f…%.0f °C)",
                                       Self.duration(now.timeIntervalSince(since)), r, range.lowerBound, range.upperBound)))
            } else if let since = t.invalidSince, now.timeIntervalSince(since) > Self.invalidSeconds,
                      (groupValidFraction[group] ?? 0) >= Self.invalidGroupValidFraction {
                out.append((id, String(format: "invalid for %@ while %.0f %% of its group (%@) is valid",
                                       Self.duration(now.timeIntervalSince(since)),
                                       (groupValidFraction[group] ?? 0) * 100, group.rawValue)))
            } else if let since = t.constantSince, let v = t.lastValue, now.timeIntervalSince(since) > Self.stuckSeconds,
                      let change = siblingChange(of: i, since: since), change >= Self.siblingChangeC {
                out.append((id, String(format: "constant %.2f °C for %@ while a sibling changed by %.1f °C",
                                       v, Self.duration(now.timeIntervalSince(since)), change)))
            }
        }
        return out.sorted { $0.0 < $1.0 }.map { (id: $0.0, reason: $0.1) }
    }

    /// max − min of the first visible sibling (same hardware group) that changed by ≥ 2 °C over [since, now], else the
    /// largest change seen (nil without sibling samples).
    private func siblingChange(of index: Int, since: Date) -> Double? {
        var best: Double?
        for j in siblings[slots[index].group] ?? [] where j != index {
            var lo = Double.infinity, hi = -Double.infinity
            for p in slots[j].track.samples.reversed() {
                if p.t < since { break }
                lo = min(lo, p.v); hi = max(hi, p.v)
            }
            guard hi >= lo else { continue }
            best = max(best ?? 0, hi - lo)
            if hi - lo >= Self.siblingChangeC { break }
        }
        return best
    }

    // MARK: Items

    public func items(context: DiagnosticsContext, now: Date) -> [DiagnosticItem] {
        DiagnosticKind.allCases.map { kind in
            let e: Evaluation
            switch kind {
            case .lastShutdown: e = lastShutdownItem(context)
            case .fans: e = fansItem(context)
            case .sensors: e = sensorsItem(context)
            case .battery: e = batteryItem(context)
            case .thermal: e = thermalItem(context)
            case .storage: e = storageItem(context)
            case .helper: e = helperItem(context)
            case .smc: e = smcItem(context)
            }
            return DiagnosticItem(id: kind, status: e.0, finding: e.1, details: e.2, updated: now)
        }
    }

    private typealias Evaluation = (DiagnosticStatus, DiagnosticFinding, [DiagnosticDetail])

    private func lastShutdownItem(_ c: DiagnosticsContext) -> Evaluation {
        let boot = c.slow.boot
        let panic = !(boot?.panicLogPath ?? "").isEmpty
        var details: [DiagnosticDetail] = []
        if let b = boot {
            func add(_ label: String, _ value: String?) { if let v = value, !v.isEmpty { details.append(DiagnosticDetail(label, v)) } }
            add("kern.shutdownreason", b.shutdownReason)
            add("kern.bootreason", b.bootReason)
            add("kern.wakereason", b.wakeReason)
            add("Last sleep reason", b.lastSleepReason)
            add("Wake type", b.wakeType)
            add("Boot time", b.bootTime.map(Self.iso))
            add("Last sleep", b.lastSleepTime.map(Self.iso))
            add("Last wake", b.lastWakeTime.map(Self.iso))
            add("Lid closed", b.lidClosed.map { $0 ? "yes" : "no" })
            add("Previous shutdown cause (Intel)", b.intelShutdownCause.map(String.init))
            add("Panic report", b.panicLogPath)
        }
        guard let verdict = c.slow.shutdownVerdict ?? (panic ? .kernelPanic : nil) else {
            return (.unknown, boot == nil ? .unknown : .shutdown(.unknown, panicLog: false), details)
        }
        details.insert(DiagnosticDetail("Classification", Self.verdictName(verdict)), at: 0)
        let status: DiagnosticStatus
        if panic || verdict == .kernelPanic { status = .error }
        else if verdict.isAbnormal { status = .warning }
        else if verdict == .unknown { status = .unknown }
        else if verdict == .other { status = .info }
        else { status = .ok }
        return (status, .shutdown(panic ? .kernelPanic : verdict, panicLog: panic), details)
    }

    private func fansItem(_ c: DiagnosticsContext) -> Evaluation {
        let p = profile.fans.isEmpty ? (c.inventory?.fanProfile ?? .none) : profile
        guard !p.fans.isEmpty else {
            // No fans discovered: fanless only when discovery actually ran on a reachable SMC.
            if let inv = c.inventory, inv.smcAvailable { return (.info, .fanless, []) }
            return (.unknown, .unknown, [])
        }
        var details: [DiagnosticDetail] = [DiagnosticDetail("Scheme", p.scheme.description)]
        if let ftst = lastFanState?.ftst { details.append(DiagnosticDetail("Ftst", String(ftst))) }
        if let fs = lastFanState?.forceBits { details.append(DiagnosticDetail("FS!", String(format: "0x%04x", fs))) }
        for fan in p.fans {
            let t = fanTracks[fan.index]
            var parts = [String(format: "range %.0f–%.0f rpm", fan.minRPM, fan.maxRPM)]
            if let s = t?.last {
                parts.insert(String(format: "%.0f rpm, target %.0f rpm", s.actualRPM, s.targetRPM), at: 0)
                if let m = s.mode { parts.append("mode \(m)") }
            }
            if t?.commandedByThermik == true, let e = t?.expectedRPM { parts.append(String(format: "Thermik commands %.0f rpm", e)) }
            details.append(DiagnosticDetail("Fan \(fan.index) (\(fan.name))", parts.joined(separator: ", ")))
        }
        if foreignControlSuspected { details.append(DiagnosticDetail("Control", "another app is forcing the fans")) }
        guard lastFanState != nil else { return (.unknown, .unknown, details) }
        let stalled = stalledFans
        let mismatch = fansNotReachingTarget.filter { !stalled.contains($0) }
        if !stalled.isEmpty {
            if !mismatch.isEmpty { details.append(DiagnosticDetail("Not reaching target", mismatch.map(String.init).joined(separator: ", "))) }
            return (.warning, .fansStalled(stalled), details)
        }
        if !mismatch.isEmpty { return (.warning, .fansNotReachingTarget(mismatch), details) }
        return (.ok, .fansOK(count: p.fans.count), details)
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
        let b = c.battery
        let apple = c.slow.appleBatteryHealth
        guard b != nil || apple != nil else { return (.info, .noBattery, []) }
        var condition = apple?.condition ?? .unknown
        if let pf = b?.permanentFailureStatus, pf != 0 { condition = .permanentFailure }
        else if condition == .unknown, b != nil { condition = .normal }    // gauge readable, no failure flag
        let health = apple?.maximumCapacityPercent.map(Double.init) ?? b?.healthPercent
        let rated = b?.designCycleCount
        var details: [DiagnosticDetail] = []
        func add(_ label: String, _ value: String?) { if let v = value { details.append(DiagnosticDetail(label, v)) } }
        add("Condition (system_profiler)", apple?.conditionRaw)
        add("Maximum capacity (Apple)", apple?.maximumCapacityPercent.map { "\($0) %" })
        add("Health (nominal / design)", b?.healthPercent.map { String(format: "%.1f %%", $0) })
        add("Health (raw max / design)", b?.rawHealthPercent.map { String(format: "%.1f %%", $0) })
        add("Cycle count", b?.cycleCount.map { c in rated.map { "\(c) of \($0)" } ?? String(c) })
        add("Design capacity", b?.designCapacity_mAh.map { "\($0) mAh" })
        add("Nominal charge capacity", b?.nominalChargeCapacity_mAh.map { "\($0) mAh" })
        add("Raw max capacity", b?.rawMaxCapacity_mAh.map { "\($0) mAh" })
        add("Temperature", b?.temperatureC.map { String(format: "%.1f °C", $0) })
        add("Permanent failure status", b?.permanentFailureStatus.map { String(format: "0x%x", $0) })
        add("Not charging reason", b?.notChargingReason.map { String(format: "0x%x", $0) })
        add("Adapter", b?.adapter?.watts.map { "\($0) W" })     // watts only: adapter names are accessory names
        let finding = DiagnosticFinding.battery(condition, healthPercent: health, cycles: b?.cycleCount, ratedCycles: rated)
        switch condition {
        case .permanentFailure, .serviceRecommended: return (.warning, finding, details)
        case .normal, .unknown:
            if let h = health, h < 80 { return (.info, finding, details) }
            return (condition == .unknown ? .unknown : .ok, finding, details)
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
        func severity(_ d: NVMeHealth) -> DiagnosticStatus {
            d.criticalWarning != 0 ? .error : (d.percentageUsed >= 90 ? .warning : .ok)
        }
        var details: [DiagnosticDetail] = []
        for (i, d) in drives.enumerated() {
            let name = [d.bsdName, d.model].compactMap { $0 }.joined(separator: " · ")
            let tb = d.dataWrittenBytes / 1e12
            var parts = ["\(d.percentageUsed) % used", "\(d.temperatureC) °C",
                         "spare \(d.availableSparePercent) % (threshold \(d.availableSpareThresholdPercent) %)",
                         String(format: "%.1f TB written", tb), "\(d.powerOnHours) h powered on",
                         "\(d.unsafeShutdowns) unsafe shutdowns", "\(d.mediaErrors) media errors"]
            if d.criticalWarning != 0 { parts.insert(String(format: "CRITICAL WARNING 0x%02x", d.criticalWarning), at: 0) }
            if let fw = d.firmware { parts.append("firmware \(fw)") }
            details.append(DiagnosticDetail(name.isEmpty ? "Drive \(i)" : name, parts.joined(separator: ", ")))
        }
        let worst = drives.max { severity($0) < severity($1) } ?? drives[0]
        return (severity(worst), .storage(percentUsed: worst.percentageUsed, temperatureC: worst.temperatureC,
                                          criticalWarning: worst.criticalWarning != 0), details)
    }

    private func helperItem(_ c: DiagnosticsContext) -> Evaluation {
        var health = c.helper
        var thermikHelper: HelperHealth?                              // Thermik's own helper behind a foreign controller
        if foreignControlSuspected {
            switch health {
            case .foreignController(let name): health = .foreignController(name ?? foreignControllerName)
            case .notApplicable: break
            default: thermikHelper = health; health = .foreignController(foreignControllerName)
            }
        }
        var details = [DiagnosticDetail("State", Self.helperName(health))]
        if let h = thermikHelper { details.append(DiagnosticDetail("Thermik helper", Self.helperName(h))) }
        if case .foreignController = health, let ftst = lastFanState?.ftst { details.append(DiagnosticDetail("Ftst", String(ftst))) }
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
        guard let inv = c.inventory else { return (.unknown, .unknown, []) }
        let finding = DiagnosticFinding.smc(available: inv.smcAvailable, keyCount: inv.smcKeyCount, catalog: inv.catalogStatus)
        let id = inv.identity
        var details = [DiagnosticDetail("SMC keys", String(inv.smcKeyCount)),
                       DiagnosticDetail("Catalog", Self.catalogName(inv.catalogStatus)),
                       DiagnosticDetail("Platform", id.platformName),
                       DiagnosticDetail("Chip", id.chipName),
                       DiagnosticDetail("Model", id.modelIdentifier)]
        if let t = id.targetType { details.append(DiagnosticDetail("Target type", t)) }
        if let s = id.smcPlatform { details.append(DiagnosticDetail("SMC platform (RPlt)", s)) }
        details.append(DiagnosticDetail("Temperature sensors", String(inv.sensors.count)))
        details.append(DiagnosticDetail("Heuristic sensor names", String(inv.sensors.filter(\.isHeuristic).count)))
        guard inv.smcAvailable else { return (.error, finding, details) }
        switch inv.catalogStatus {
        case .verified: return (.ok, finding, details)
        case .unverified, .heuristic: return (.info, finding, details)
        }
    }

    // MARK: Report

    /// Markdown report for GitHub issues. NEVER includes serial numbers, UUIDs or accessory names.
    public func report(items: [DiagnosticItem], machine: MachineInfo?, inventory: SensorInventory?, appVersion: String) -> String {
        var md = "## Thermik diagnostics report\n\n"
        md += "| | |\n|---|---|\n"
        func row(_ k: String, _ v: String?) { if let v, !v.isEmpty { md += "| \(k) | \(Self.cell(v)) |\n" } }
        row("Generated", Self.iso(Date()))
        row("App", "Thermik \(appVersion)")
        row("macOS", machine?.osVersion ?? ProcessInfo.processInfo.operatingSystemVersionString)
        row("Model", machine.map { m in m.marketingName.map { "\(m.modelIdentifier) (\($0))" } ?? m.modelIdentifier }
            ?? inventory?.identity.modelIdentifier)
        row("Chip", machine?.chip ?? inventory?.identity.chipName)
        if let m = machine {
            row("Memory", m.memoryBytes > 0 ? "\(m.memoryBytes >> 30) GB" : nil)
            row("CPUs", m.perfLevels.isEmpty ? String(m.logicalCPUs)
                : m.perfLevels.map { "\($0.logicalCPUs) \($0.name)" }.joined(separator: " + "))
            row("GPU", m.gpuName.map { n in m.gpuCores.map { "\(n), \($0) cores" } ?? n })
            row("Rosetta", m.isTranslated ? "yes" : nil)
        }
        if let inv = inventory {
            row("Sensor catalog", Self.catalogName(inv.catalogStatus))
            row("SMC", inv.smcAvailable ? "\(inv.smcKeyCount) keys" : "unavailable")
            row("Temperature sensors", String(inv.sensors.count))
        }
        let p = profile.fans.isEmpty ? (inventory?.fanProfile ?? .none) : profile
        row("Fan scheme", p.scheme.description)
        row("Fans", p.fans.isEmpty ? "none"
            : p.fans.map { String(format: "%d: %.0f–%.0f rpm", $0.index, $0.minRPM, $0.maxRPM) }.joined(separator: "; "))
        if let h = items.first(where: { $0.id == .helper }), case .helper(let health) = h.finding { row("Helper", Self.helperName(health)) }

        md += "\n### Checks\n\n| Check | Status | Result |\n|---|---|---|\n"
        for item in items {
            md += "| \(item.id.rawValue) | \(Self.statusName(item.status)) | \(Self.cell(Self.summary(item.finding))) |\n"
        }
        md += "\n### Details\n"
        for item in items where !item.details.isEmpty {
            md += "\n**\(item.id.rawValue)** (\(Self.statusName(item.status)))\n\n"
            for d in item.details { md += "- \(d.label): `\(d.value.replacingOccurrences(of: "`", with: "'"))`\n" }
        }
        return Self.redact(md)
    }

    /// ADDED (Unit 6): the "Recent events" Markdown section (newest last), redacted. DiagnosticsStore appends it
    /// to `report(…)` (the frozen signature has no events parameter).
    public static func eventsMarkdown(_ events: [AppEvent], limit: Int = 50) -> String {
        var md = "\n### Recent events\n\n"
        let recent = events.suffix(limit)
        if recent.isEmpty { return md + "_none_\n" }
        md += "```\n"
        for e in recent { md += "\(iso(e.date))  \(e.payload.csvToken)\n" }
        md += "```\n"
        return redact(md)
    }

    /// ADDED (Unit 6): removes identifying strings: 10–12 character upper-case alphanumerics that mix letters and
    /// digits (Apple serial numbers), UUIDs, MAC / Bluetooth addresses, the user's home path and the host name.
    public static func redact(_ text: String) -> String {
        var s = text
        let home = NSHomeDirectory()
        if home.count > 1 { s = s.replacingOccurrences(of: home, with: "~") }
        let rules: [(String, String)] = [
            (#"/Users/[^/\s`|]+"#, "/Users/[user]"),
            (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "[uuid]"),
            (#"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#, "[mac-address]"),
            (#"(?<![A-Za-z0-9])(?=[A-Z0-9]{10,12}(?![A-Za-z0-9]))(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10,12}"#, "[serial]"),
        ]
        for (pattern, template) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        if let host = hostName(), host.count >= 3 { s = s.replacingOccurrences(of: host, with: "[host]") }
        return s
    }

    private static func hostName() -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return nil }
        let name = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let short = name.split(separator: ".").first.map(String.init) ?? name
        return short.isEmpty || short == "localhost" ? nil : short
    }

    // MARK: Known fan controllers (naming only)

    /// ADDED (Unit 6): launchd labels of known fan-control helpers (public identifiers). Only the PRESENCE of their
    /// plist / executable is checked; nothing is opened or read. Detection itself is the SMC state
    /// (`foreignControlSuspected`); these only put a name on it.
    public static let knownFanControlHelpers: [(label: String, product: String)] = [
        ("com.tunabellysoftware.TGFanHelper", "TG Pro"),
        ("com.crystalidea.macsfancontrol.smcwrite", "Macs Fan Control"),
        ("eu.exelban.Stats.SMC.Helper", "Stats"),
    ]

    /// ADDED (Unit 6): SMC clients that are NOT fan controllers although they run a root helper that opens the SMC
    /// (battery charge limiters such as AlDente). Never reported as a fan controller.
    public static let knownNonFanSMCClients = ["aldente"]

    /// ADDED (Unit 6): products of `knownFanControlHelpers` installed on this Mac (launchd plist or helper present).
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

    /// ADDED (Unit 6): false for names of known non-fan SMC clients (AlDente's helper and the like).
    public static func isPlausibleFanController(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !knownNonFanSMCClients.contains { lower.contains($0) }
    }

    // MARK: English names (report and details only; the app localizes findings itself)

    public static func summary(_ f: DiagnosticFinding) -> String {
        switch f {
        case .shutdown(let v, let panic): return verdictName(v) + (panic ? " (panic report present)" : "")
        case .fansOK(let n): return "\(n) fan\(n == 1 ? "" : "s") OK"
        case .fanless: return "no fans (passively cooled)"
        case .fansStalled(let ids): return "stalled: fan " + ids.map(String.init).joined(separator: ", ")
        case .fansNotReachingTarget(let ids): return "not reaching target: fan " + ids.map(String.init).joined(separator: ", ")
        case .sensorsOK(let n): return "\(n) sensors, none suspect"
        case .sensorsSuspect(let ids): return "suspect: " + ids.map(\.description).joined(separator: ", ")
        case .battery(let c, let h, let cycles, let rated):
            var parts = [conditionName(c)]
            if let h { parts.append(String(format: "health %.0f %%", h)) }
            if let cycles { parts.append(rated.map { "\(cycles) of \($0) cycles" } ?? "\(cycles) cycles") }
            return parts.joined(separator: ", ")
        case .noBattery: return "no battery"
        case .thermal(let p, let n): return "\(pressureName(p)), \(n) event\(n == 1 ? "" : "s") today"
        case .storage(let used, let temp, let critical):
            guard used != nil || temp != nil || critical else { return "no NVMe health data" }
            var parts: [String] = []
            if critical { parts.append("CRITICAL WARNING") }
            if let used { parts.append("\(used) % used") }
            if let temp { parts.append("\(temp) °C") }
            return parts.joined(separator: ", ")
        case .helper(let h): return helperName(h)
        case .smc(let available, let keys, let catalog):
            return available ? "\(keys) keys, \(catalogName(catalog)) catalog" : "SMC unavailable"
        case .unknown: return "no data"
        }
    }

    public static func verdictName(_ v: ShutdownVerdict) -> String {
        switch v {
        case .normalRestart: return "normal restart"
        case .normalShutdown: return "normal shutdown"
        case .forced: return "forced (power button)"
        case .thermal: return "overheating"
        case .powerLoss: return "power loss or empty battery"
        case .watchdog: return "watchdog reset"
        case .kernelPanic: return "kernel panic"
        case .intelCode(let c): return "shutdown cause code \(c)"
        case .other: return "other"
        case .unknown: return "unknown"
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
