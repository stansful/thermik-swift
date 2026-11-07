// FanStore.swift — Thermik (MIT).
// The fan-control POLICY (SPEC §2.9.4): live fans, foreign-controller detection, status, the 1 Hz engine tick,
// Max auto-revert, safety events, error handling, sleep/wake/quit. The helper command pipeline (send-only-changes,
// in-flight guard, lease renewal) lives in FanControlCoordinator.
//
// Tick order: FanStore consumes after SensorStore / SystemStore / HistoryStore (§2.3.3), so `sensors.aggregates`
// (smoothed) and `system.pressure` are this tick's values. Nothing here awaits inside `consume`.
import Foundation
import Observation
import os
import ThermikCore
import ThermikHelperShared
import ThermikSMC

@MainActor @Observable final class LiveFan: Identifiable {
    let descriptor: FanDescriptor
    nonisolated var id: Int { descriptor.index }
    var displayName: String
    private(set) var actualRPM: Double = 0
    private(set) var targetRPM: Double?
    private(set) var modeValue: FanModeValue?
    private(set) var dutyCycle: Double?
    /// Apple Silicon parks fans at 0 rpm when cool: render "Off (macOS)", not an error.
    private(set) var isOff = true
    var minRPM: Double { descriptor.minRPM }
    var maxRPM: Double { descriptor.maxRPM }
    var percentOfMax: Double { maxRPM > 0 ? min(max(actualRPM / maxRPM, 0), 1) * 100 : 0 }

    init(descriptor: FanDescriptor, displayName: String) { self.descriptor = descriptor; self.displayName = displayName }

    func update(_ s: FanSnapshot) {
        // Assign only on change: every assignment of an @Observable property invalidates the views reading it.
        if actualRPM != s.actualRPM { actualRPM = s.actualRPM }
        let target = s.targetRPM > 0 ? s.targetRPM : nil
        if targetRPM != target { targetRPM = target }
        if modeValue != s.mode { modeValue = s.mode }
        if dutyCycle != s.dutyCycle { dutyCycle = s.dutyCycle }
        if isOff != s.isOff { isOff = s.isOff }
    }
}

@MainActor @Observable final class FanStore: TickConsumer {
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let sensors: SensorStore
    @ObservationIgnored let system: SystemStore
    @ObservationIgnored let helper: HelperManager
    @ObservationIgnored let events: EventLogStore
    @ObservationIgnored let router: AppRouter

    private(set) var profile: FanHardwareProfile = .none
    private(set) var fans: [LiveFan] = []
    private(set) var mode: FanMode = .system
    private(set) var status: FanControlStatus = .monitoringOnly(.connecting)
    /// ◆ badge: Thermik currently holds manual control of at least one fan.
    private(set) var isOverriding = false
    private(set) var maxRevertDeadline: Date?
    private(set) var lastCommands: [Int: FanCommand] = [:]
    private(set) var foreignControllerName: String?
    /// Live operating point for the curve editor (engine input temperature, smoothed).
    private(set) var curveInputC: Double?
    /// P1 fan test in progress (every fan at Mx for `fanTestSeconds`).
    private(set) var isTestingFans = false
    /// Another app forces the fans (SMC state); the mode switcher is disabled while true.
    private(set) var foreignControlActive = false

    // MARK: Tuning (SPEC §2.9.4)

    /// Retries of a refused Ftst unlock (30 s apart) before the mode returns to System.
    static let maxUnlockRetries = 3
    static let unlockRetryDelay: TimeInterval = 30
    /// Consecutive generic helper errors (5 s apart) before giving up.
    static let maxGenericFailures = 5
    static let genericRetryDelay: TimeInterval = 5
    /// Forcing must be seen twice within this window to count as a foreign controller (single-sample glitches).
    static let foreignConfirmWindow: TimeInterval = 10
    /// The foreign state clears after this long without any forcing (absorbs controllers that pulse Ftst).
    static let foreignClearSeconds: TimeInterval = 15
    /// Forcing right after Thermik's own release is the SMC catching up (read-back lags ~250 ms), not foreign.
    static let releaseGraceSeconds: TimeInterval = 5
    /// While Thermik holds the fans: an SMC target this far from what Thermik wrote, on this many consecutive ticks
    /// read at least `foreignTargetSettle` after Thermik's last command, is another controller writing.
    static let foreignTargetToleranceRPM: Double = 50
    static let foreignTargetTicks = 3
    static let foreignTargetSettle: TimeInterval = 1
    /// More lost leases than this within the window: stop re-asserting (macOS keeps reclaiming, the helper keeps
    /// reverting) and leave the fans on Auto with an explanation.
    static let maxLeaseLosses = 3
    static let leaseLossWindow: TimeInterval = 120
    /// A helper revert this recent (helper clock) explains the lost lease; an older one is a previous revert's.
    static let revertReasonFreshness: TimeInterval = 30
    /// Helper reverts that end fan control instead of a re-send: its own safety (I8/I9) gave up on these fans.
    static let helperSafetyReverts: Set<String> = ["sensorFailure", "overrideWriteFailed", "overrideReleaseFailed", "stopRestartFailed"]
    /// SMCClientInspector (IORegistry walk) at most this often.
    static let inspectorInterval: TimeInterval = 10
    static let wakeReapplyDelay: Duration = .seconds(3)
    static let fanTestSeconds: Duration = .seconds(10)
    /// Debug override of `maxAutoRevertMinutes`: `open Thermik.app --args -ThermikMaxRevertMinutes 1`.
    static let maxRevertOverrideKey = "ThermikMaxRevertMinutes"

    // MARK: Private state

    @ObservationIgnored private let coordinator: FanControlCoordinator
    @ObservationIgnored private var engine: FanControlEngine?
    @ObservationIgnored private let logger = Logger(subsystem: "app.thermik.Thermik", category: "fans")
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var errorMessage: String?
    @ObservationIgnored private var unlockFailures = 0
    @ObservationIgnored private var genericFailures = 0
    @ObservationIgnored private var helperSafetyUntil: Date?
    @ObservationIgnored private var safetyEventActive = false
    @ObservationIgnored private var foreignSightings: [Date] = []
    @ObservationIgnored private var foreignCheckInFlight = false
    @ObservationIgnored private var lastForeignSeenAt: Date?
    @ObservationIgnored private var foreignTargetMismatches = 0
    @ObservationIgnored private var leaseLosses: [Date] = []
    /// `maxAutoRevertMinutes` the current Max deadline was computed from (a change while in Max re-arms it).
    @ObservationIgnored private var revertMinutesInEffect: Int?
    @ObservationIgnored private var lastInspectorRun: Date?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var inWakeHold = false
    @ObservationIgnored private var sleepStartedAt: Date?
    @ObservationIgnored private var fanTestTask: Task<Void, Never>?

    init(settings: SettingsStore, sensors: SensorStore, system: SystemStore, helper: HelperManager, events: EventLogStore,
         router: AppRouter) {
        self.settings = settings; self.sensors = sensors; self.system = system; self.helper = helper; self.events = events
        self.router = router
        coordinator = FanControlCoordinator(helper: helper)
        coordinator.onStateChange = { [weak self] in self?.refreshStatus() }
        coordinator.onSuccess = { [weak self] in self?.commandSucceeded() }
        coordinator.onFailure = { [weak self] f in self?.commandFailed(f) }
        coordinator.onLeaseLost = { [weak self] in self?.leaseLost() }
    }

    var hasFans: Bool { !profile.fans.isEmpty }
    var config: FanUserConfig { settings.fans }
    /// Helper ready, fans present, no foreign controller.
    var canControl: Bool { hasFans && profile.isControllable && helper.isReady && !foreignControlActive }

    /// For SamplingCoordinator (§2.3.4): tick at 1 Hz while Thermik controls, engages or is about to.
    var needsFastTicks: Bool {
        coordinator.mayHoldFans || isTestingFans || (canControl && mode != .system)
    }

    /// For SamplingCoordinator: per-sensor inputs the fan engine and the curve editor read (aggregates are always
    /// sampled; a curve driven by one specific sensor must be added to the request).
    var requiredSensorIDs: Set<SensorID> {
        var ids: Set<SensorID> = []
        for curve in [config.curveAC, config.curveBattery].compactMap({ $0 }) {
            if case .sensor(let id) = curve.input { ids.insert(id) }
        }
        return ids
    }

    // MARK: Load

    func load(profile: FanHardwareProfile, names: [String]?) {
        let profileChanged = profile != self.profile
        self.profile = profile
        fans = makeFans(profile: profile, names: names)
        if profileChanged || engine == nil { engine = profile.fans.isEmpty ? nil : FanControlEngine(profile: profile) }
        restoreInitialModeIfNeeded()
        refreshStatus()
    }

    private func makeFans(profile: FanHardwareProfile, names: [String]?) -> [LiveFan] {
        profile.fans.map { fan in
            let databaseName = names?.indices.contains(fan.index) == true ? names?[fan.index] : nil
            return LiveFan(descriptor: fan, displayName: Self.displayName(dbName: databaseName, descriptor: fan))
        }
    }

    private func restoreInitialModeIfNeeded() {
        guard !loaded else { return }
        loaded = true
        // §2.3.5 launch step 8: System unless the user asked to restore the last mode.
        restoreLaunchMode()
    }

    private func restoreLaunchMode() {
        if config.restoreModeOnLaunch, config.mode != .system, hasFans {
            restoreMode(config.mode)
        } else if settings.fans.mode != .system {
            settings.fans.mode = .system
        }
    }

    private func restoreMode(_ newMode: FanMode) {
        mode = newMode
        events.record(.fanModeChanged(FanModeChange(from: .system, to: newMode, reason: .launch)))
        updateMaxRevertDeadline()
        router.requestTick()
    }

    // MARK: Tick

    func consume(_ tick: Tick) {
        let now = tick.date
        updateFans(from: tick.sensors.fans)
        guard hasFans else { refreshStatus(); return }
        recoverFromMissedWake()
        if let state = tick.sensors.fans, !helper.isDemo { updateForeignController(state, now: now) }
        updateMaxAutoRevert(at: now)
        runEngine(now: now)
        updateSafetyEvent()
        refreshStatus()
    }

    private func updateFans(from state: FanControlState?) {
        guard let state else { return }
        for snapshot in state.fans { fans.first { $0.id == snapshot.index }?.update(snapshot) }
    }

    private func recoverFromMissedWake() {
        // Sampling resumed long after willSleep without a didWake (missed notification): leave the hold.
        guard inWakeHold, wakeTask == nil, let since = sleepStartedAt, Date().timeIntervalSince(since) > 30 else { return }
        logger.notice("no didWake after willSleep; resuming fan control")
        inWakeHold = false
        sleepStartedAt = nil
        coordinator.systemDidWake()
        engine?.resetState()
    }

    private func updateMaxAutoRevert(at now: Date) {
        // "Return to Auto after" changed while in Max (Settings › Fans writes the setting directly): re-arm.
        if mode == .max, config.maxAutoRevertMinutes != revertMinutesInEffect { armMaxRevert(from: now) }
        guard mode == .max, let deadline = maxRevertDeadline, now >= deadline else { return }
        changeMode(.system, reason: .maxAutoRevert)
    }

    /// The curve that is (or would be) in use for the current power source.
    private var activeCurve: FanCurve {
        system.powerSourceKind == .battery ? (config.curveBattery ?? config.curveAC) : config.curveAC
    }

    private var systemCommands: [Int: FanCommand] {
        Dictionary(uniqueKeysWithValues: profile.fans.map { ($0.index, FanCommand.system) })
    }

    private var fanTestCommands: [Int: FanCommand] {
        Dictionary(uniqueKeysWithValues: profile.fans.map { ($0.index, FanCommand.rpm($0.maxRPM)) })
    }

    private func runEngine(now: Date) {
        guard let engine else { return }
        let curve = activeCurve
        // Auto (System) is macOS's alone: Thermik's engine — curve, guard, safety latch — runs only in its own modes.
        guard canControl, !inWakeHold else { useSystemCommands(for: curve); return }
        guard mode != .system || isTestingFans else { releaseToSystem(curve, now: now); return }
        runControlledEngine(engine, curve: curve, now: now)
    }

    private func useSystemCommands(for curve: FanCurve) {
        setLastCommands(systemCommands)
        setCurveInput(sensors.value(curve.input))
    }

    private func releaseToSystem(_ curve: FanCurve, now: Date) {
        useSystemCommands(for: curve)
        // Helper ready but nothing to do: make sure nothing is held (no-op when already released).
        coordinator.apply(systemCommands, now: now)
    }

    private func runControlledEngine(_ engine: FanControlEngine, curve: FanCurve, now: Date) {
        let plan = FanPlanBuilder.plan(config: config, power: system.powerSourceKind, profile: profile)
        let readings = temperatureReadings(for: plan)
        var commands = engine.tick(now: now, temperatures: readings.temperatures, gated: readings.gated,
                                   safetyTempC: sensors.aggregates[.safetyTop4],
                                   rawHottestC: sensors.rawAggregates[.rawHottestDie], pressure: system.pressure, plan: plan)
        if isTestingFans { commands = fanTestCommands }
        setLastCommands(commands)
        updateControlledCurveInput(engine, curve: curve)
        coordinator.apply(commands, now: now, safety: engine.safetyLatched || engine.thermalGuardActive)
    }

    private func temperatureReadings(for plan: FanPlan) -> (temperatures: [TemperatureSource: Double], gated: Set<TemperatureSource>) {
        var temperatures: [TemperatureSource: Double] = [:]
        var gated: Set<TemperatureSource> = []
        for source in plan.referencedSources {
            if let value = sensors.value(source) { temperatures[source] = value }
            // A P-cluster die past its 30 s hold reads nothing while the cluster is idle: not a lost sensor.
            else if case .sensor(let id) = source, sensors.sensor(id)?.state == .gated { gated.insert(source) }
        }
        return (temperatures, gated)
    }

    private func updateControlledCurveInput(_ engine: FanControlEngine, curve: FanCurve) {
        let value = mode == .curve ? engine.smoothedTemperature(curve.input) ?? sensors.value(curve.input)
                                   : sensors.value(curve.input)
        setCurveInput(value)
    }

    private func setLastCommands(_ c: [Int: FanCommand]) { if lastCommands != c { lastCommands = c } }

    private func setCurveInput(_ t: Double?) {
        switch (curveInputC, t) {
        case (nil, nil): return
        case let (old?, new?) where abs(old - new) < 0.05: return
        default: curveInputC = t
        }
    }

    // MARK: Foreign controller (§2.9.4 step 2)

    /// Not holding the fans: SMC forcing that cannot be Thermik's own is another app. "Ours" comes from the
    /// coordinator, never from a cached helper snapshot: Thermik holds the fans or did within one lease (the helper
    /// reverts when it runs out, I3), or released them moments ago. While engaged: `detectForeignWriter`.
    private func updateForeignController(_ state: FanControlState, now: Date) {
        guard !coordinator.isOverriding else { detectForeignWriter(state, now: now); return }
        foreignTargetMismatches = 0
        let ours = ownForcing(at: now)
        if state.anyManual && (foreignControlActive || !ours) { observeUnownedForcing(state, now: now); return }
        clearForeignControllerIfNeeded(state, now: now)
    }

    private func ownForcing(at now: Date) -> Bool {
        coordinator.helperMayHoldFans(now: now)
            || (coordinator.lastReleaseAt.map { now.timeIntervalSince($0) < Self.releaseGraceSeconds } ?? false)
    }

    private func observeUnownedForcing(_ state: FanControlState, now: Date) {
        // Once detected, any forcing keeps the state (Thermik itself is on Auto then and holds nothing).
        lastForeignSeenAt = now
        foreignSightings = foreignSightings.filter { now.timeIntervalSince($0) <= Self.foreignConfirmWindow } + [now]
        if !foreignControlActive, foreignSightings.count >= 2 {
            confirmForeignControl(evidence: state.forcingSignals.joined(separator: ", "))
        } else if foreignControlActive {
            refreshForeignName(now: now)
        }
    }

    private func clearForeignControllerIfNeeded(_ state: FanControlState, now: Date) {
        guard foreignControlActive, !state.anyManual, let last = lastForeignSeenAt,
              now.timeIntervalSince(last) >= Self.foreignClearSeconds else { return }
        foreignControlActive = false
        foreignControllerName = nil
        foreignSightings.removeAll()
        logger.notice("foreign fan controller gone")
    }

    /// Thermik holds the fans, so `anyManual` is its own forcing and the helper's I10 check ran only at take-over.
    /// Another controller writing now shows up as an SMC target Thermik did not write (or a fan Thermik released
    /// being forced). Ignored while a command is in flight, right after one, and while the helper's own override
    /// holds every fan at max; a macOS reclaim (mode back to System) is the lease's business.
    private func detectForeignWriter(_ state: FanControlState, now: Date) {
        guard !coordinator.hasCommandInFlight, !helperSafetyActive, let sentAt = coordinator.lastCommandAt else {
            foreignTargetMismatches = 0
            return
        }
        let evidence = foreignEvidence(state, sentAt: sentAt)
        foreignTargetMismatches = evidence.isEmpty ? 0 : foreignTargetMismatches + 1
        guard foreignTargetMismatches >= Self.foreignTargetTicks else { return }
        foreignTargetMismatches = 0
        engageForeignControl(now: now, evidence: "while Thermik held the fans: " + evidence.joined(separator: "; "))
    }

    private func foreignEvidence(_ state: FanControlState, sentAt: Date) -> [String] {
        var evidence: [String] = []
        for snapshot in state.fans {
            guard let fan = profile.fan(snapshot.index), snapshot.timestamp.timeIntervalSince(sentAt) >= Self.foreignTargetSettle else { continue }
            guard isForced(snapshot, state: state) else { continue }
            if isExpectedStop(snapshot, fan: fan) { continue }
            appendForeignEvidence(for: snapshot, fan: fan, to: &evidence)
        }
        return evidence
    }

    private func isForced(_ snapshot: FanSnapshot, state: FanControlState) -> Bool {
        let forcedBit = state.forceBits.map { $0 & (1 << UInt16(snapshot.index)) != 0 }
        return snapshot.mode == .manual || (snapshot.mode == nil && forcedBit == true)
    }

    private func isExpectedStop(_ snapshot: FanSnapshot, fan: FanDescriptor) -> Bool {
        // A stop request is the helper's to keep: stopped while the die is cool, at the minimum while it is hot.
        guard coordinator.lastSent[snapshot.index] == .rpm(0) else { return false }
        return snapshot.targetRPM < Self.foreignTargetToleranceRPM
            || abs(snapshot.targetRPM - fan.minRPM) <= Self.foreignTargetToleranceRPM
    }

    private func appendForeignEvidence(for snapshot: FanSnapshot, fan: FanDescriptor, to evidence: inout [String]) {
        if let applied = coordinator.appliedRPM[snapshot.index] {
            let tolerance = Self.foreignTargetToleranceRPM
            if abs(snapshot.targetRPM - applied) > tolerance, abs(snapshot.targetRPM - fan.maxRPM) > tolerance {
                evidence.append("fan \(snapshot.index) target \(Int(snapshot.targetRPM)) rpm, Thermik wrote \(Int(applied))")
            }
        } else if coordinator.lastSent[snapshot.index] == .system {
            evidence.append("fan \(snapshot.index) forced, released by Thermik")
        }
    }

    /// Asks the helper first: it may still be handing back fans Thermik let go of (a restore it retries while its
    /// recovery marker stays, I7), and that forcing is Thermik's own. Without that check stopped fans whose release
    /// the SMC refused were blamed on TG Pro (M4 Max, 2026-10-27). With no ready helper the forcing counts as foreign.
    private func confirmForeignControl(evidence: String) {
        guard helper.isReady else { engageForeignControl(now: Date(), evidence: evidence); return }
        guard !foreignCheckInFlight else { return }
        foreignCheckInFlight = true
        Task { @MainActor [weak self] in await self?.verifyForeignControl(evidence: evidence) }
    }

    private func verifyForeignControl(evidence: String) async {
        await helper.fetchState()
        foreignCheckInFlight = false
        guard helper.lastHelperState?.isControlling != true else {
            foreignSightings.removeAll()
            logger.notice("fans forced while the helper still holds them (restore pending): not another app")
            return
        }
        engageForeignControl(now: Date(), evidence: evidence)
    }

    private func engageForeignControl(now: Date, evidence: String) {
        lastForeignSeenAt = now
        if !foreignControlActive {
            foreignControlActive = true
            foreignControllerName = helper.conflictingHelpers.first
            logger.notice("foreign fan controller detected: \(evidence)")
        }
        lastInspectorRun = nil
        refreshForeignName(now: now)
        if mode != .system { changeMode(.system, reason: .foreignController) }
        refreshStatus()
    }

    /// Names the culprit off the main thread (IORegistry walk + proc_pidpath), at most every 10 s.
    private func refreshForeignName(now: Date) {
        if let last = lastInspectorRun, now.timeIntervalSince(last) < Self.inspectorInterval { return }
        lastInspectorRun = now
        Task.detached(priority: .utility) { [weak self] in
            let name = SMCClientInspector.suspectedFanControllers().first ?? SMCClientInspector.installedFanControlHelpers().first
            await self?.foreignNameResolved(name)
        }
    }

    private func foreignNameResolved(_ name: String?) {
        guard foreignControlActive else { return }
        let resolved = name ?? helper.conflictingHelpers.first
        if foreignControllerName != resolved { foreignControllerName = resolved }
        refreshStatus()
    }

    // MARK: Status, safety

    private var engineSafetyActive: Bool {
        (engine?.safetyLatched ?? false) && lastCommands.values.contains { $0 != .system }
    }

    private var helperSafetyActive: Bool { helperSafetyUntil.map { Date() < $0 } ?? false }

    private var safetyTemperature: Double {
        sensors.aggregates[.safetyTop4] ?? engine?.safetyTemperatureC ?? sensors.rawAggregates[.rawHottestDie] ?? 0
    }

    private func refreshStatus() {
        let current = currentStatus()
        if status != current { status = current }
        if isOverriding != coordinator.isOverriding { isOverriding = coordinator.isOverriding }
    }

    private func currentStatus() -> FanControlStatus {
        if !hasFans { return .fanless }
        if !profile.isComplete && !profile.isControllable { return incompleteProfileStatus() }
        if foreignControlActive { return .foreignController(name: foreignControllerName) }
        if !helper.isReady { return .monitoringOnly(helper.availability ?? .connecting) }
        if engineSafetyActive || helperSafetyActive { return .safetyOverride(temperatureC: safetyTemperature) }
        if let message = errorMessage { return .error(message) }
        if coordinator.isEngaging { return .engaging }
        if coordinator.isOverriding { return .active }
        return .system
    }

    private func incompleteProfileStatus() -> FanControlStatus {
        // Discovery could not read every fan on all-or-nothing hardware (runs once per launch).
        .error(String(localized: "Not every fan could be read, so Thermik does not control the fans. Quit and reopen Thermik to try again."))
    }

    private func updateSafetyEvent() {
        let active = engineSafetyActive || helperSafetyActive
        guard active != safetyEventActive else { return }
        safetyEventActive = active
        let t = safetyTemperature
        events.record(.safetyOverride(engaged: active, temperatureC: t > 0 ? t : nil))
        if active { logger.notice("safety override engaged at \(t, privacy: .public) °C") }
        else { logger.notice("safety override released at \(t, privacy: .public) °C") }
    }

    // MARK: Coordinator callbacks

    private func commandSucceeded() {
        unlockFailures = 0
        genericFailures = 0
        helperSafetyUntil = nil
        if errorMessage != nil { errorMessage = nil; refreshStatus() }
    }

    private func commandFailed(_ failure: FanCommandFailure) {
        handleCommandFailure(failure, at: Date())
        refreshStatus()
    }

    private func handleCommandFailure(_ failure: FanCommandFailure, at now: Date) {
        switch failure {
        case .unlockTimeout(let detail): unlockFailed(detail, at: now)
        case .foreignController: engageForeignControl(now: now, evidence: "helper refused: foreign controller")
        case .safetyOverride: safetyOverrideFailed(at: now)
        case .sleeping, .rateLimited, .interrupted: break                 // wake path / next tick re-applies
        case .unavailable: helperUnavailable()
        case .notControllable(let detail): notControllable(detail)
        case .failed(let detail): genericCommandFailed(detail, at: now)
        }
    }

    private func unlockFailed(_ detail: String, at now: Date) {
        unlockFailures += 1
        events.record(.error(String(localized: "Fan control error: \(detail)")))
        guard unlockFailures <= Self.maxUnlockRetries else {
            giveUp(String(localized: "macOS did not hand over fan control. The fans are back on Auto."))
            return
        }
        errorMessage = String(localized: "macOS did not hand over fan control yet. Retrying in 30 s.")
        coordinator.backOff(until: now.addingTimeInterval(Self.unlockRetryDelay))
    }

    private func safetyOverrideFailed(at now: Date) {
        helperSafetyUntil = now.addingTimeInterval(10)                 // refreshed by every refusal
        coordinator.suspend(until: now.addingTimeInterval(2))
    }

    private func helperUnavailable() {
        errorMessage = nil                                             // status becomes monitoring-only
        engine?.resetState()
    }

    private func notControllable(_ detail: String) {
        events.record(.error(String(localized: "Fan control error: \(detail)")))
        giveUp(String(localized: "This Mac's fans cannot be controlled."))
    }

    private func genericCommandFailed(_ detail: String, at now: Date) {
        genericFailures += 1
        events.record(.error(String(localized: "Fan control error: \(detail)")))
        guard genericFailures < Self.maxGenericFailures else {
            giveUp(String(localized: "Fan control stopped after repeated errors. The fans are back on Auto."))
            return
        }
        errorMessage = String(localized: "The helper could not change the fan speed. Retrying…")
        coordinator.backOff(until: now.addingTimeInterval(Self.genericRetryDelay))
    }

    /// Mode back to System, keeping the explanation visible until the user picks a mode again.
    private func giveUp(_ message: String, reason: FanModeChangeReason = .helperUnavailable) {
        changeMode(.system, reason: reason)
        errorMessage = message
    }

    /// `renewLease` replied false (or the lease ran out during an engine stall). The coordinator re-sends nothing
    /// until `leaseLostResolved` read why: re-asserting a helper SAFETY revert would loop engage → revert forever.
    private func leaseLost() {
        engine?.resetState()
        let lostAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.helper.fetchState()
            self.leaseLostResolved(self.helper.lastHelperState, lostAt: lostAt)
        }
    }

    private func leaseLostResolved(_ state: HelperState?, lostAt: Date) {
        let reason = leaseLossReason(state, lostAt: lostAt)
        events.record(.helperReverted(reason: reason))
        // The user (or a give-up) returned to Auto meanwhile: nothing to re-assert.
        guard mode != .system || isTestingFans else {
            coordinator.resumeAfterLeaseLoss()
            return
        }
        leaseLosses = leaseLosses.filter { lostAt.timeIntervalSince($0) <= Self.leaseLossWindow } + [lostAt]
        resolveLeaseLoss(reason)
        refreshStatus()
    }

    private func leaseLossReason(_ state: HelperState?, lostAt: Date) -> String {
        // Still controlling: macOS reclaimed a fan and the helper holds the others. Otherwise the helper restored
        // System, and its reason counts only if it is this revert's, not an older one's.
        if state?.isControlling == true { return "macOSReclaimed" }
        if let reason = state?.lastRevertReason, let at = state?.lastRevertDate,
           abs(lostAt.timeIntervalSince(at)) <= Self.revertReasonFreshness { return reason }
        return "leaseLost"
    }

    private func resolveLeaseLoss(_ reason: String) {
        if Self.helperSafetyReverts.contains(reason) { helperSafetyLeaseLost(reason); return }
        if leaseLosses.count > Self.maxLeaseLosses { excessiveLeaseLosses(reason); return }
        resumeAfterLeaseLoss(reason)
    }

    private func helperSafetyLeaseLost(_ reason: String) {
        logger.error("the helper returned the fans to System (\(reason, privacy: .public)): fan control stopped")
        events.record(.error(String(localized: "Fan control error: \(HelperRevertReason.title(reason))")))
        giveUp(String(localized: "The helper returned the fans to Auto because it could not read the temperatures or set the fan speed safely."),
               reason: .safety)
    }

    private func excessiveLeaseLosses(_ reason: String) {
        logger.error("lease lost \(self.leaseLosses.count, privacy: .public) times in \(Int(Self.leaseLossWindow), privacy: .public) s (last: \(reason, privacy: .public)): fan control stopped")
        giveUp(String(localized: "Fan control stopped because the fans kept returning to Auto."))
    }

    private func resumeAfterLeaseLoss(_ reason: String) {
        logger.notice("lease lost (\(reason, privacy: .public)): re-sending")
        coordinator.resumeAfterLeaseLoss()
        router.requestTick()
    }

    // MARK: Commands (UI contract §2.9.4)

    func setMode(_ newMode: FanMode, reason: FanModeChangeReason = .user) {
        changeMode(newMode, reason: reason)
    }

    private func changeMode(_ newMode: FanMode, reason: FanModeChangeReason) {
        guard newMode == .system || canControl else { refuseModeChange(newMode); return }
        if newMode == mode, newMode != .system { repeatCurrentMode(newMode); return }
        recordModeChange(newMode, reason: reason)
        resetForModeChange(newMode)
        updateMaxRevertDeadline()
        applyMode(newMode, reason: reason)
        refreshStatus()
    }

    private func refuseModeChange(_ newMode: FanMode) {
        logger.notice("mode change to \(newMode.rawValue) refused: fan control unavailable")
        refreshStatus()
    }

    private func repeatCurrentMode(_ currentMode: FanMode) {
        // Re-selecting the mode in effect (a glass switcher tap, a menu item, a shortcut) changes nothing: the
        // engine keeps its state (a curve inside its hysteresis band stays engaged). Max restarts its countdown.
        if currentMode == .max { armMaxRevert(from: Date()) }
        if settings.fans.mode != currentMode { settings.fans.mode = currentMode }
        refreshStatus()
    }

    private func recordModeChange(_ newMode: FanMode, reason: FanModeChangeReason) {
        guard newMode != mode else { return }
        events.record(.fanModeChanged(FanModeChange(from: mode, to: newMode, reason: reason)))
        mode = newMode
    }

    private func resetForModeChange(_ newMode: FanMode) {
        if settings.fans.mode != newMode { settings.fans.mode = newMode }
        errorMessage = nil
        unlockFailures = 0
        genericFailures = 0
        leaseLosses.removeAll()
        engine?.resetState()
    }

    private func updateMaxRevertDeadline() {
        if mode == .max {
            armMaxRevert(from: Date())
        } else {
            maxRevertDeadline = nil
        }
    }

    private func applyMode(_ newMode: FanMode, reason: FanModeChangeReason) {
        guard newMode == .system else { router.requestTick(); return }
        guard !isTestingFans else { return }
        setLastCommands(systemCommands)
        if helper.isReady || coordinator.mayHoldFans { coordinator.releaseAll(reason: "mode System (\(reason.rawValue))") }
    }

    /// (Re)starts the Max countdown from `now` with the current "Return to Auto after" value.
    private func armMaxRevert(from now: Date) {
        revertMinutesInEffect = config.maxAutoRevertMinutes
        maxRevertDeadline = revertDeadline(from: now)
    }

    private func revertDeadline(from now: Date) -> Date? {
        // Launch arguments land in the argument domain as strings: `integer(forKey:)` converts them.
        let d = UserDefaults.standard
        let override = d.object(forKey: Self.maxRevertOverrideKey) != nil ? d.integer(forKey: Self.maxRevertOverrideKey) : nil
        guard let minutes = override ?? config.maxAutoRevertMinutes, minutes > 0 else { return nil }
        return now.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    /// "Return to Auto after" for Max (nil or ≤ 0 = never). Picked during a Max session, it applies to that session:
    /// the countdown restarts from now with the new value (a change from Settings is picked up on the next tick).
    func setMaxAutoRevert(minutes: Int?) {
        let m = minutes.flatMap { $0 > 0 ? $0 : nil }
        guard settings.fans.maxAutoRevertMinutes != m else { return }
        settings.fans.maxAutoRevertMinutes = m
        if mode == .max { armMaxRevert(from: Date()); refreshStatus() }
    }

    /// `fan: nil` sets one speed for every fan and links them (the popover slider, a fan-less thermik:// link):
    /// unlinked fans would keep their own values and ignore it. Per-fan values are kept for a later unlink.
    func setFixedPercent(_ percent: Double, fan: Int?) {
        let p = percent.isFinite ? min(max(percent, 0), 100) : 50
        var config = settings.fans
        updateFixedPercent(&config, percent: p, fan: fan)
        // An unchanged value writes no settings and requests no tick.
        guard config != settings.fans else { return }
        settings.fans = config
        if mode == .fixed { router.requestTick() }
    }

    private func updateFixedPercent(_ config: inout FanUserConfig, percent: Double, fan: Int?) {
        if let fan {
            config.fixedPercentPerFan[fan] = percent
        } else {
            config.fixedPercent = percent
            config.linked = true
        }
    }

    func setLinked(_ linked: Bool) {
        guard settings.fans.linked != linked else { return }
        settings.fans.linked = linked
        if mode == .fixed { router.requestTick() }
    }

    func applyCurve(_ curve: FanCurve, for power: PowerSourceKind) {
        if power == .battery { settings.fans.curveBattery = curve } else { settings.fans.curveAC = curve }
        if mode == .curve { router.requestTick() }
    }

    /// Stores the preset as the AC curve (the mode is not changed; the UI calls `setMode(.curve)` to use it).
    func applyPreset(_ id: FanPresetID) { applyCurve(FanPresets.curve(id), for: .ac) }

    /// "Reset to System": force-release everything (also clears state Thermik did not record).
    func resetToSystem() {
        fanTestTask?.cancel()
        isTestingFans = false
        changeMode(.system, reason: .user)
        if helper.isReady { coordinator.releaseAll(reason: "reset to System") }
    }

    /// P1: each fan to max for 10 s (user-initiated, helper required), then back to the current mode.
    func runFanTest() async {
        guard canControl, !isTestingFans else { return }
        beginFanTest()
        let task = Task { @MainActor in _ = try? await Task.sleep(for: Self.fanTestSeconds) }
        fanTestTask = task
        await task.value
        guard isTestingFans else { return }                              // cancelled by Reset to System
        finishFanTest()
    }

    private func beginFanTest() {
        isTestingFans = true
        logger.notice("fan test started")
        engine?.resetState()
        router.requestTick()
    }

    private func finishFanTest() {
        isTestingFans = false
        fanTestTask = nil
        engine?.resetState()
        router.requestTick()
        logger.notice("fan test finished")
    }

    func systemWillSleep() {
        wakeTask?.cancel()
        wakeTask = nil
        inWakeHold = true
        sleepStartedAt = Date()
        coordinator.systemWillSleep()                                    // resetAllFans (the helper also restores)
        engine?.resetState()
        refreshStatus()
    }

    func systemDidWake() {
        wakeTask?.cancel()
        inWakeHold = true
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.wakeReapplyDelay)
            self?.completeWake()
        }
    }

    private func completeWake() {
        guard !Task.isCancelled else { return }
        inWakeHold = false
        sleepStartedAt = nil
        wakeTask = nil
        coordinator.systemDidWake()
        engine?.resetState()
        router.requestTick()
        refreshStatus()
    }

    /// applicationWillTerminate: bounded synchronous restore (≤ 2 s).
    func prepareForTermination() {
        wakeTask?.cancel()
        fanTestTask?.cancel()
        coordinator.resetAllBlocking(timeout: 2)
    }

    // MARK: Names

    /// Localized fan name: DB names ("Left"/"Right") and the discovery fallbacks map to the glossary terms; Intel
    /// `F%dID` names ("Exhaust", …) are shown as reported.
    static func displayName(dbName: String?, descriptor: FanDescriptor) -> String {
        let raw = (dbName ?? descriptor.name).trimmingCharacters(in: .whitespaces)
        switch raw.lowercased() {
        case "left", "left fan": return String(localized: "Left fan")
        case "right", "right fan": return String(localized: "Right fan")
        case "fan": return String(localized: "Fan")
        case "", "fan \(descriptor.index + 1)": return String(localized: "Fan \(descriptor.index + 1)")
        default: return raw
        }
    }
}
