// HelperService.swift — Thermik (MIT). HELPER ONLY.
//
// The helper is a dumb, safe actuator: the app decides targets, this service enforces the invariants of
// Fan safety and lifecycle policy around the `FanControlling` write layer:
//   I1  targets finite, ≥ 0, clamped to the SMC's own [Mn, Mx]; the client gets the applied rpm
//   I3  lease: no command / renewal for `lease` s → System            (1 Hz watchdog)
//   I4  last client gone → System after a 3 s grace                    (connectionClosed)
//   I5  SIGTERM / SIGINT / SIGHUP → restore, exit 0                    (shutdown(reason:), wired by main.swift)
//   I6  sleep → restore before IOAllowPowerChange; `sleeping` until wake (systemWillSleep / systemDidWake)
//   I7  crash marker written BEFORE the first manual write, removed after a full restore; restore at start
//       (min-only Intel: the marker also carries the original F%dMn bytes, written before a minimum is raised)
//   I8  thermal override → every fan to Mx, lower targets refused (`safetyOverride`); failed write → System
//   I9  no readable die sensor while controlling → System
//   I10 never fight another controller (`foreignController`)
//   I11 rate limit 20 commands/s                                       (sliding 1 s window)
//   I13 idle exit after 120 s with no clients and no manual fans       (onIdleExit)
// Merge of research/helper/skeleton/Helper/HelperService.swift (lease, rate limit, marker, idle exit) and
// research/fans/code/HelperOnly/FanControlService.swift (foreign refusal, override, sleeping flag, revert reasons).
//
// Concurrency: every piece of mutable state, and every call into `FanControlling`, runs on the serial `stateQueue`
// — that is what makes `@unchecked Sendable` sound. NSXPC calls the exported object on its own private queues;
// the endpoint hops onto `stateQueue` with `async` and replies from there, so a long Ftst unlock (≤ 12 s) never
// blocks an XPC queue. The public synchronous methods use `stateQueue.sync` and must not be called ON that queue.
import Foundation
import os
import ThermikSMC
import ThermikSMCWriter
import ThermikHelperShared

public final class HelperService: @unchecked Sendable {   // state confined to `stateQueue`; `onIdleExit` behind `lock`
    public struct Config: Sendable {
        public var watchdogInterval: TimeInterval = 1.0
        public var idleExitSeconds: Double = ThermikHelper.Limits.idleExitSeconds
        public var markerPath: String? = ThermikHelper.manualMarkerPath
        /// I4: delay between the last client disconnecting and the restore (absorbs quick reconnects).
        public var clientGoneGraceSeconds: Double = ThermikHelper.Limits.clientGoneGraceSeconds
        /// I11: commands accepted per sliding second (resetAllFans / uninstall are never limited).
        public var maxCommandsPerSecond: Int = ThermikHelper.Limits.maxCommandsPerSecond
        /// After an incomplete restore, how long until the next forced attempt.
        public var restoreRetrySeconds: Double = 10
        public init() {}
    }

    /// Called on the state queue when the helper may exit: no clients, no manual fans, idle for `idleExitSeconds`.
    /// It must not call back into the service synchronously (main.swift passes `exit(0)`).
    public var onIdleExit: (@Sendable () -> Void)? {
        get { lock.withLock { idleHandler } }
        set { lock.withLock { idleHandler = newValue } }
    }

    private typealias Instant = ContinuousClock.Instant

    private let stateQueue = DispatchQueue(label: "\(ThermikHelper.label).state", qos: .userInitiated)
    private let lock = NSLock()
    private var idleHandler: (@Sendable () -> Void)?
    private let fans: FanControlling
    /// The same controller when it can persist original F%dMn bytes (intelMinimumOnly; SMCFanController).
    private let minimumRecovery: MinimumOnlyRecovery?
    private let installKind: HelperInstallKind
    private let config: Config
    private let marker: RecoveryMarkerStore
    private let clock = ContinuousClock()

    // State (stateQueue only).
    private var started = false
    private var isShuttingDown = false
    private var idleExitRequested = false
    private var sleeping = false
    private var overrideActive = false
    private var leaseDeadline: Instant?
    private var lastActivity: Instant
    private var connections: Set<UInt64> = []
    private var clientGoneWork: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
    private var commandTimes: [Instant] = []
    /// Last clamped target the app asked for, per fan (re-applied when a thermal override ends).
    private var requestedRPM: [Int: Double] = [:]
    /// What the marker on disk currently says (avoids an fsync per command).
    private var writtenMarker: (fans: [Int], ftst: Bool, minimums: [Int: [UInt8]])?
    private var restoreRetryAt: Instant?
    /// The thermal override just ended: fans stay at maximum until this deadline, then return to what the app last
    /// asked for. Commands that arrive meanwhile apply at once. A request older than the app's own safety latch (sent
    /// before it, or refused during the override) must not dip the fans before the app re-asserts maximum.
    private var overrideReleaseHoldUntil: Instant?
    /// Hottest die sensor of the last watchdog check (nil before the first one / without readable sensors).
    private var lastHottestC: Double?
    private static let overrideReleaseHold: Duration = .seconds(5)
    /// A stop held at the minimum (hot die) applies again this far below `stopRefusedHottestC`.
    private static let stopResumeMarginC: Double = 5
    private var lastRevertReason: String?
    private var lastRevertDate: Date?
    /// The startup recovery wrote back a crashed instance's original F%dMn bytes (see `needsFanRediscovery`).
    private var fanProfileStale = false

    public init(fans: FanControlling, installKind: HelperInstallKind, config: Config = Config()) {
        self.fans = fans
        self.minimumRecovery = fans as? MinimumOnlyRecovery
        self.installKind = installKind
        self.config = config
        self.marker = RecoveryMarkerStore(path: config.markerPath)
        self.lastActivity = clock.now
        // Runs inside `setManual`, i.e. on the state queue.
        minimumRecovery?.willRaiseMinimum = { [weak self] fan in
            guard let self else { return }
            try self.persistMinimumLocked(fan)
        }
    }

    // MARK: Lifecycle (public, synchronous)

    /// Call once at startup: crash recovery (I7), then the 1 Hz watchdog. If the per-boot marker exists, a
    /// previous instance died while controlling → `forceRestoreAll`. Otherwise the fans are left alone.
    public func start() {
        stateQueue.sync {
            guard !started, !isShuttingDown else { return }
            started = true
            recoverLocked()
            startWatchdogLocked()
            lastActivity = clock.now
            logServiceStartedLocked()
        }
    }

    private func startWatchdogLocked() {
        let interval = max(0.05, config.watchdogInterval)
        let t = DispatchSource.makeTimerSource(queue: stateQueue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        t.setEventHandler { [weak self] in self?.watchdogTickLocked() }
        t.resume()
        watchdog = t
    }

    private func logServiceStartedLocked() {
        let p = fans.profile
        serviceLog.notice("service started: kind \(self.installKind.rawValue, privacy: .public), \(p.fans.count, privacy: .public) fans, scheme \(p.scheme.description, privacy: .public)")
    }

    /// SIGTERM / SIGINT / SIGHUP / uninstall (I5): synchronously return every fan to System and stop the watchdog.
    public func shutdown(reason: String) {
        stateQueue.sync {
            let wasShuttingDown = isShuttingDown
            isShuttingDown = true
            watchdog?.cancel(); watchdog = nil
            clientGoneWork?.cancel(); clientGoneWork = nil
            if fans.isControlling || overrideActive || marker.exists {
                forceRevertLocked(reason: reason)
            }
            if !wasShuttingDown { serviceLog.notice("shutdown (\(reason, privacy: .public))") }
        }
    }

    /// kIOMessageSystemWillSleep (I6): restore NOW — the caller acknowledges the sleep only after this returns —
    /// and refuse commands with `sleeping` until `systemDidWake()`. The app re-applies its targets ~3 s after wake.
    public func systemWillSleep() {
        stateQueue.sync {
            sleeping = true
            if fans.isControlling || overrideActive { revertLocked(reason: "sleep") }
            powerLog.notice("system will sleep: commands are refused until wake")
        }
    }

    /// kIOMessageSystemHasPoweredOn.
    public func systemDidWake() {
        stateQueue.sync {
            sleeping = false
            lastActivity = clock.now
            powerLog.notice("system did wake")
        }
    }

    // MARK: In-process inspection (thermik-probe selftest; not reachable over XPC)

    /// Current state, exactly as `getState()` would report it.
    public func stateSnapshot() -> HelperState { stateQueue.sync { stateLocked() } }

    /// True once `start()` wrote back the original F%dMn bytes a crashed instance had raised (intelMinimumOnly).
    /// The fan profile was discovered before that, with the raised values as minimums (they shift every clamp and
    /// the app's 0 %), so main.swift exits and launchd relaunches the helper with a fresh discovery on demand.
    public var needsFanRediscovery: Bool { stateQueue.sync { fanProfileStale } }

    /// Runs `body` on the state queue with the fan controller (e.g. to flip a MockFanController's simulated values
    /// without racing the watchdog). Must not be called on the state queue.
    public func withController<T>(_ body: (FanControlling) throws -> T) rethrows -> T {
        try stateQueue.sync { try body(fans) }
    }

    // MARK: Connection bookkeeping (HelperXPCServer)

    func connectionOpened(_ token: UInt64) {
        stateQueue.async { [self] in
            connections.insert(token)
            clientGoneWork?.cancel(); clientGoneWork = nil
            lastActivity = clock.now
        }
    }

    /// Idempotent: invalidation and interruption may both report the same connection.
    func connectionClosed(_ token: UInt64) {
        stateQueue.async { [self] in
            guard connections.remove(token) != nil else { return }
            lastActivity = clock.now
            guard connections.isEmpty, fans.isControlling || overrideActive else { return }
            let work = makeClientGoneWork()
            clientGoneWork?.cancel()
            clientGoneWork = work
            stateQueue.asyncAfter(deadline: .now() + config.clientGoneGraceSeconds, execute: work)
        }
    }

    private func makeClientGoneWork() -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            guard let self, self.connections.isEmpty, self.fans.isControlling || self.overrideActive else { return }
            serviceLog.notice("last client gone for \(self.config.clientGoneGraceSeconds, privacy: .public) s")
            self.revertLocked(reason: "clientGone")                              // I4
        }
    }

    // MARK: Commands (HelperEndpoint; reply from the state queue)

    func hello(clientProtocolVersion: Int, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        let received = clock.now
        stateQueue.async { [self] in
            lastActivity = received
            helloLocked(clientProtocolVersion: clientProtocolVersion, reply: reply)
        }
    }

    private func helloLocked(clientProtocolVersion: Int, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        guard clientProtocolVersion == ThermikHelper.protocolVersion else {
            serviceLog.notice("hello: client protocol \(clientProtocolVersion, privacy: .public) ≠ \(ThermikHelper.protocolVersion, privacy: .public)")
            reply(nil, .thermikHelper(.unsupportedProtocol,
                                      "client protocol \(clientProtocolVersion), helper protocol \(ThermikHelper.protocolVersion)"))
            return
        }
        Self.replyEncoded(infoLocked(), reply)
    }

    func getState(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        let received = clock.now
        stateQueue.async { [self] in
            if let e = rateLimitLocked(received) { reply(nil, e); return }
            lastActivity = received
            Self.replyEncoded(stateLocked(), reply)
        }
    }

    func setFanTarget(fanIndex: Int, rpm: Double, leaseSeconds: Double, reply: @escaping @Sendable (Double, NSError?) -> Void) {
        let received = clock.now
        stateQueue.async { [self] in
            let (applied, error) = setFanTargetLocked(fanIndex, rpm: rpm, lease: leaseSeconds, received: received)
            reply(applied, error)
        }
    }

    func setFanAutomatic(fanIndex: Int, reply: @escaping @Sendable (NSError?) -> Void) {
        let received = clock.now
        stateQueue.async { [self] in reply(setFanAutomaticLocked(fanIndex, received: received)) }
    }

    func renewLease(leaseSeconds: Double, reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        let received = clock.now
        stateQueue.async { [self] in
            let (still, error) = renewLeaseLocked(leaseSeconds, received: received)
            reply(still, error)
        }
    }

    /// Idempotent, never refused. Only touches the fans if Thermik holds them (or holds a marker): an explicit
    /// "Reset to System" must not clobber another fan-control app either (I10).
    func resetAllFans(reason: String, reply: @escaping @Sendable (NSError?) -> Void) {
        stateQueue.async { [self] in
            lastActivity = clock.now
            if fans.isControlling || overrideActive || marker.exists {
                forceRevertLocked(reason: reason)
            } else {
                serviceLog.info("resetAllFans: nothing to restore")
            }
            reply(nil)
        }
    }

    /// Legacy installs only: restore, then run `handler` (delete own files, schedule bootout). `notPermitted` otherwise.
    func uninstallLegacy(_ handler: (@Sendable () throws -> Void)?, reply: @escaping @Sendable (NSError?) -> Void) {
        stateQueue.async { [self] in
            guard installKind == .legacy, let handler else {
                reply(.thermikHelper(.notPermitted, "self-uninstall exists only for legacy installs (this helper: \(installKind.rawValue))"))
                return
            }
            performLegacyUninstallLocked(handler, reply: reply)
        }
    }

    private func performLegacyUninstallLocked(_ handler: @Sendable () throws -> Void,
                                              reply: @escaping @Sendable (NSError?) -> Void) {
        if fans.isControlling || overrideActive || marker.exists { forceRevertLocked(reason: "uninstall") }
        do {
            try handler()
            reply(nil)
        } catch {
            serviceLog.error("legacy uninstall failed: \(error.localizedDescription, privacy: .public)")
            reply(.thermikHelper(.internalError, "uninstall failed: \(error.localizedDescription)"))
        }
    }

    // MARK: Command bodies (stateQueue)

    private struct FanTargetRequest {
        let index: Int
        let fan: FanDescriptor
        let rpm: Double
        let lease: Double
        let wantsStop: Bool
        let target: Double
    }

    private func setFanTargetLocked(_ index: Int, rpm: Double, lease: Double, received: Instant) -> (Double, NSError?) {
        switch prepareFanTargetLocked(index, rpm: rpm, lease: lease, received: received) {
        case .failure(let error): return (0, error)
        case .success(let request): return applyFanTargetLocked(request)
        }
    }

    private func prepareFanTargetLocked(_ index: Int, rpm: Double, lease: Double,
                                        received: Instant) -> Result<FanTargetRequest, NSError> {
        if isShuttingDown { return .failure(.thermikHelper(.internalError, "the helper is shutting down")) }
        if let e = rateLimitLocked(received) { return .failure(e) }
        lastActivity = received
        let profile = fans.profile
        guard profile.isControllable else { return .failure(.thermikHelper(.notControllable, "fans are not controllable on this Mac")) }
        return makeFanTargetRequestLocked(profile, index: index, rpm: rpm, lease: lease)
    }

    /// I1: clamp to [Mn, Mx]; exactly 0 = a stop request (Apple Silicon), applied only on a cool die right now.
    private func makeFanTargetRequestLocked(_ profile: FanHardwareProfile, index: Int, rpm: Double,
                                            lease: Double) -> Result<FanTargetRequest, NSError> {
        guard let fan = profile.fan(index) else { return .failure(.thermikHelper(.fanNotFound, "no fan \(index)")) }
        guard rpm.isFinite, rpm >= 0 else { return .failure(.thermikHelper(.invalidArgument, "rpm must be finite and not negative")) }
        guard let lease = Self.clampedLease(lease) else { return .failure(.thermikHelper(.invalidArgument, "lease must be finite and positive")) }
        if sleeping { return .failure(.thermikHelper(.sleeping, "the system is sleeping")) }
        let wantsStop = rpm == 0 && profile.scheme.allowsFanStop
        let target = effectiveTargetLocked(fan, rpm)
        let request = FanTargetRequest(index: index, fan: fan, rpm: rpm, lease: lease,
                                       wantsStop: wantsStop, target: target)
        logStopHeldIfNeededLocked(request)
        return .success(request)
    }

    private func logStopHeldIfNeededLocked(_ request: FanTargetRequest) {
        guard request.wantsStop, request.target > 0 else { return }
        serviceLog.notice("fan \(request.index, privacy: .public) stop held at the minimum: die \(self.lastHottestC.map { String(format: "%.1f °C", $0) } ?? "unreadable", privacy: .public)")
    }

    private func applyFanTargetLocked(_ request: FanTargetRequest) -> (Double, NSError?) {
        if overrideActive { return applyOverrideFanTargetLocked(request) }                 // I8
        if fans.isControlling { return adjustFanTargetLocked(request) }
        return takeOverFanTargetLocked(request)
    }

    private func takeOverFanTargetLocked(_ request: FanTargetRequest) -> (Double, NSError?) {
        if let error = prepareTakeoverLocked(request.index) { return (0, error) }
        let (applied, error) = writeFanTargetLocked(request)
        if let error { return (0, error) }
        return completeTakeoverFanTargetLocked(request, applied: applied)
    }

    private func adjustFanTargetLocked(_ request: FanTargetRequest) -> (Double, NSError?) {
        let (applied, error) = writeFanTargetLocked(request)
        if let error { return (0, error) }
        return completeAdjustmentFanTargetLocked(request, applied: applied)
    }

    private func writeFanTargetLocked(_ request: FanTargetRequest) -> (Double, NSError?) {
        do {
            let applied = try fans.setManual(request.index, targetRPM: request.target)
            return (applied, nil)
        } catch {
            return failedFanTargetLocked(request, error: error)
        }
    }

    private func applyOverrideFanTargetLocked(_ request: FanTargetRequest) -> (Double, NSError?) {
        requestedRPM[request.index] = request.wantsStop ? 0 : request.target
        extendLeaseLocked(request.lease)
        return (fans.appliedRPM[request.index] ?? request.fan.maxRPM,
                .thermikHelper(.safetyOverride, "thermal override active: fans held at maximum"))
    }

    private func prepareTakeoverLocked(_ index: Int) -> NSError? {
        if let error = foreignControllerErrorLocked(index) { return error }
        do {
            try writeMarkerLocked(owned: fans.ownedFans.union([index]))                    // I7: marker FIRST
        } catch {
            serviceLog.error("cannot write the recovery marker: \(error.localizedDescription, privacy: .public)")
            return .thermikHelper(.internalError, "cannot write the recovery marker")
        }
        return nil
    }

    private func foreignControllerErrorLocked(_ index: Int) -> NSError? {
        guard !marker.exists, fans.foreignControlSuspected() else { return nil }           // I10
        serviceLog.notice("refused manual control of fan \(index, privacy: .public): another controller is forcing the fans")
        return .thermikHelper(.foreignController, "another app is controlling the fans")
    }

    private func failedFanTargetLocked(_ request: FanTargetRequest, error: any Error) -> (Double, NSError?) {
        if !fans.isControlling { removeMarkerLocked() }      // nothing was taken over
        let wire = Self.wireError(error)
        serviceLog.error("fan \(request.index, privacy: .public) manual \(Int(request.target), privacy: .public) rpm failed: \(wire.localizedDescription, privacy: .public)")
        return (0, wire)
    }

    private func completeTakeoverFanTargetLocked(_ request: FanTargetRequest, applied: Double) -> (Double, NSError?) {
        requestedRPM[request.index] = request.wantsStop ? 0 : applied // a stop stays requested while held at minimum
        extendLeaseLocked(request.lease)
        updateMarkerLocked()
        serviceLog.notice("manual control engaged: fan \(request.index, privacy: .public) \(Int(applied), privacy: .public) rpm, lease \(request.lease, privacy: .public) s")
        return (applied, nil)
    }

    private func completeAdjustmentFanTargetLocked(_ request: FanTargetRequest, applied: Double) -> (Double, NSError?) {
        requestedRPM[request.index] = request.wantsStop ? 0 : applied // a stop stays requested while held at minimum
        extendLeaseLocked(request.lease)
        updateMarkerLocked()
        serviceLog.info("fan \(request.index, privacy: .public) → \(Int(applied), privacy: .public) rpm (asked \(request.rpm, privacy: .public))")
        return (applied, nil)
    }

    private func setFanAutomaticLocked(_ index: Int, received: Instant) -> NSError? {
        if let e = rateLimitLocked(received) { return e }
        lastActivity = received
        guard fans.profile.fan(index) != nil else { return .thermikHelper(.fanNotFound, "no fan \(index)") }
        let owned = fans.ownedFans
        guard owned.contains(index) else { return releaseUnownedFanLocked(index, owned: owned) }
        if owned == [index] { return releaseLastFanLocked() }
        if overrideActive { return .thermikHelper(.safetyOverride, "thermal override active: fans held at maximum") }
        return releaseOwnedFanLocked(index)
    }

    private func releaseUnownedFanLocked(_ index: Int, owned: Set<Int>) -> NSError? {
        // Not ours: never touch it. If nothing is owned but Ftst is still ours, finish the release.
        if owned.isEmpty, fans.isControlling { revertLocked(reason: "released") }
        requestedRPM[index] = nil
        return nil
    }

    private func releaseLastFanLocked() -> NSError? {
        revertLocked(reason: "released")       // last owned fan → full restore (also clears Ftst)
        return nil
    }

    private func releaseOwnedFanLocked(_ index: Int) -> NSError? {
        do {
            try fans.setAutomatic(index)
        } catch {
            return Self.wireError(error)
        }
        requestedRPM[index] = nil
        updateMarkerLocked()
        serviceLog.info("fan \(index, privacy: .public) back to System")
        return nil
    }

    private func renewLeaseLocked(_ lease: Double, received: Instant) -> (Bool, NSError?) {
        switch prepareLeaseRenewalLocked(lease, received: received) {
        case .failure(let error): return (false, error)
        case .success(let lease):
            guard fans.isControlling || overrideActive else { return (false, nil) }   // reverted: the app re-sends
            extendLeaseLocked(lease)
            return leaseRenewalStatusLocked()
        }
    }

    private func prepareLeaseRenewalLocked(_ lease: Double, received: Instant) -> Result<Double, NSError> {
        if let e = rateLimitLocked(received) { return .failure(e) }
        guard let lease = Self.clampedLease(lease) else { return .failure(.thermikHelper(.invalidArgument, "lease must be finite and positive")) }
        lastActivity = received
        if sleeping { return .failure(.thermikHelper(.sleeping, "the system is sleeping")) }
        return .success(lease)
    }

    private func leaseRenewalStatusLocked() -> (Bool, NSError?) {
        let reclaimed = fans.reclaimedFans()
        if !reclaimed.isEmpty {
            serviceLog.notice("macOS reclaimed fan(s) \(reclaimed.map(String.init).joined(separator: ","), privacy: .public)")
            return (false, nil)
        }
        return (true, nil)
    }

    // MARK: Watchdog (stateQueue, 1 Hz)

    private func watchdogTickLocked() {
        guard !isShuttingDown else { return }
        let now = clock.now
        if fans.isControlling || overrideActive {
            watchdogControlTickLocked(now)
        } else {
            watchdogWithoutControlTickLocked(now)
        }
        idleCheckLocked(now)
    }

    private func watchdogControlTickLocked(_ now: Instant) {
        if leaseDeadline == nil { extendLeaseLocked(ThermikHelper.Limits.defaultLeaseSeconds) }   // defensive
        if let deadline = leaseDeadline, now >= deadline {
            serviceLog.notice("lease expired")
            revertLocked(reason: "leaseExpired")                                    // I3
            return
        }
        let verdict = fans.evaluateSafety()
        applySafetyLocked(verdict)                                                            // I8, I9
        reconcileStopsLocked(verdict)
        releaseOverrideHoldIfDueLocked(now)
    }

    private func releaseOverrideHoldIfDueLocked(_ now: Instant) {
        guard let until = overrideReleaseHoldUntil, now >= until, !overrideActive else { return }
        overrideReleaseHoldUntil = nil
        restoreRequestedLocked()
    }

    private func watchdogWithoutControlTickLocked(_ now: Instant) {
        leaseDeadline = nil
        if let retry = restoreRetryAt, now >= retry, marker.exists {
            forceRevertLocked(reason: "restoreRetry")
        }
    }

    /// What a requested rpm becomes: [Mn, Mx], or 0 for a stop request when a die reading taken right now is below
    /// `stopRefusedHottestC`. No reading (no die keys, link down) counts as hot: fail closed, the fan keeps spinning.
    private func effectiveTargetLocked(_ fan: FanDescriptor, _ rpm: Double) -> Double {
        guard rpm == 0, fans.profile.scheme.allowsFanStop else { return fan.clamp(rpm) }
        let hot = fans.currentHottestDieC()
        lastHottestC = hot
        guard let h = hot, h < ThermikHelper.Safety.stopRefusedHottestC else { return fan.minRPM }
        return 0
    }

    /// Fans the app asked to stop (requested 0): stopped while the dies are cool, at their minimum while hot. The
    /// watchdog's reading restarts a stopped fan at ≥ `stopRestartHottestC` (or with no reading) and stops a held one
    /// again once the dies are `stopResumeMarginC` below the refusal line, so neither a refusal nor a restart is
    /// permanent and the app never has to resend its stop.
    private func reconcileStopsLocked(_ verdict: SafetyVerdict) {
        guard !overrideActive, overrideReleaseHoldUntil == nil, fans.profile.scheme.allowsFanStop else { return }
        let stopFans = fans.profile.fans.filter { fans.ownedFans.contains($0.index) && requestedRPM[$0.index] == 0 }
        guard !stopFans.isEmpty else { return }
        let hot = Self.hottestC(for: verdict)
        lastHottestC = hot
        for fan in stopFans {
            guard reconcileStopLocked(fan, hot: hot) else { return }
        }
        updateMarkerLocked()
    }

    private static func hottestC(for verdict: SafetyVerdict) -> Double? {
        switch verdict {
        case .normal(let h): h
        case .override(let h, _): h
        case .sensorFailure: nil
        }
    }

    private func reconcileStopLocked(_ fan: FanDescriptor, hot: Double?) -> Bool {
        do {
            try applyStopActionLocked(fan, hot: hot)
        } catch {
            revertLocked(reason: "stopRestartFailed")
            return false
        }
        return true
    }

    private func applyStopActionLocked(_ fan: FanDescriptor, hot: Double?) throws {
        let applied = fans.appliedRPM[fan.index] ?? fan.minRPM
        let restart = hot.map { $0 >= ThermikHelper.Safety.stopRestartHottestC } ?? true
        let resume = hot.map { $0 < ThermikHelper.Safety.stopRefusedHottestC - Self.stopResumeMarginC } ?? false
        if applied == 0, restart {
            try restartStoppedFanLocked(fan, hot: hot)
        } else if applied > 0, resume {
            try resumeStoppedFanLocked(fan, hot: hot)
        }
    }

    private func restartStoppedFanLocked(_ fan: FanDescriptor, hot: Double?) throws {
        _ = try fans.setManual(fan.index, targetRPM: fan.minRPM)
        serviceLog.notice("stopped fan \(fan.index, privacy: .public) restarted: die \(hot.map { String(format: "%.1f °C", $0) } ?? "unreadable", privacy: .public)")
    }

    private func resumeStoppedFanLocked(_ fan: FanDescriptor, hot: Double?) throws {
        _ = try fans.setManual(fan.index, targetRPM: 0)
        serviceLog.notice("fan \(fan.index, privacy: .public) stopped again: die \(String(format: "%.1f °C", hot ?? 0), privacy: .public)")
    }

    private func applySafetyLocked(_ verdict: SafetyVerdict) {
        switch verdict {
        case .sensorFailure:
            serviceLog.error("no readable die sensor: returning the fans to System")
            revertLocked(reason: "sensorFailure")
        case let .override(hottest, top4):
            engageThermalOverrideLocked(hottest: hottest, top4: top4)
        case .normal:
            releaseThermalOverrideLocked()
        }
    }

    private func engageThermalOverrideLocked(hottest: Double, top4: Double) {
        if !overrideActive {
            overrideActive = true
            serviceLog.notice("thermal override: hottest \(hottest, privacy: .public) °C, top-4 mean \(top4, privacy: .public) °C → every fan to maximum")
        }
        guard forceFansToMaximumLocked() else { return }
        updateMarkerLocked()
    }

    private func forceFansToMaximumLocked() -> Bool {
        for fan in fans.profile.fans {
            guard forceFanToMaximumLocked(fan) else { return false }
        }
        return true
    }

    private func forceFanToMaximumLocked(_ fan: FanDescriptor) -> Bool {
        let atMax = fans.ownedFans.contains(fan.index) && abs((fans.appliedRPM[fan.index] ?? -1) - fan.maxRPM) <= 1
        if atMax { return true }
        do {
            _ = try fans.setManual(fan.index, targetRPM: fan.maxRPM)
            return true
        } catch {
            serviceLog.error("thermal override write failed on fan \(fan.index, privacy: .public): \(Self.wireError(error).localizedDescription, privacy: .public)")
            revertLocked(reason: "overrideWriteFailed")
            return false
        }
    }

    private func releaseThermalOverrideLocked() {
        guard overrideActive else { return }
        overrideActive = false
        // Fans stay at maximum for a moment: the app re-sends its targets, then the rest return to its requests.
        overrideReleaseHoldUntil = clock.now.advanced(by: Self.overrideReleaseHold)
        serviceLog.notice("thermal override released; holding maximum for 5 s while the app re-sends its targets")
    }

    /// Back to what the app last asked for; fans it never asked for return to System.
    private func restoreRequestedLocked() {
        guard fans.isControlling else { return }
        guard !requestedRPM.isEmpty else { revertLocked(reason: "overrideReleased"); return }
        do {
            try restoreRequestedFansLocked()
        } catch {
            revertLocked(reason: "overrideReleaseFailed")
            return
        }
        updateMarkerLocked()
    }

    private func restoreRequestedFansLocked() throws {
        for fan in fans.profile.fans {
            if let rpm = requestedRPM[fan.index] {
                _ = try fans.setManual(fan.index, targetRPM: effectiveTargetLocked(fan, rpm))   // a stop only on a cool die
            } else if fans.ownedFans.contains(fan.index) {
                try fans.setAutomatic(fan.index)
            }
        }
    }

    private func idleCheckLocked(_ now: Instant) {
        guard !idleExitRequested, connections.isEmpty, !fans.isControlling, !overrideActive,
              Self.seconds(now - lastActivity) >= config.idleExitSeconds,
              let handler = lock.withLock({ idleHandler }) else { return }
        idleExitRequested = true
        serviceLog.notice("idle for \(Int(self.config.idleExitSeconds), privacy: .public) s with no clients: exiting (launchd relaunches on demand)")
        handler()
    }

    // MARK: Internals (stateQueue)

    private func recoverLocked() {
        let contents = marker.read()
        guard let ftstSetByUs = prepareRecoveryLocked(contents) else { return }
        let adoptedMinimums = !(minimumRecovery?.savedMinimumBytes.isEmpty ?? true)
        fans.adoptPersistedState(ftstSetByUs: ftstSetByUs)
        forceRevertLocked(reason: "startupRecovery")
        if adoptedMinimums, minimumRecovery?.savedMinimumBytes.isEmpty == true {
            fanProfileStale = true
            serviceLog.notice("original fan minimums restored; the fan profile was read while they were raised")
        }
    }

    private func prepareRecoveryLocked(_ contents: RecoveryMarkerStore.Contents) -> Bool? {
        switch contents {
        case .absent: return nil
        case .valid(let m): return prepareValidRecoveryLocked(m)
        case .unreadable:
            serviceLog.notice("unreadable recovery marker: restoring System")
            return fans.profile.hasFtstKey
        }
    }

    private func prepareValidRecoveryLocked(_ marker: RecoveryMarker) -> Bool {
        serviceLog.notice("recovery marker of pid \(marker.pid, privacy: .public) (fans \(marker.fans.map(String.init).joined(separator: ","), privacy: .public)): restoring System")
        // intelMinimumOnly: the forced restore below writes the crashed instance's original minimums back.
        if let saved = marker.savedMinimumBytes, !saved.isEmpty { minimumRecovery?.adoptSavedMinimumBytes(saved) }
        return marker.ftstSetByUs
    }

    /// Every fan back to System (never throws). The marker is removed only after a complete restore; otherwise
    /// it stays (a crash now still recovers) and a forced retry is scheduled. With a marker on disk the restore is
    /// always forced: the forcing it covers is Thermik's (I7, I10), and a helper that restarted after a failed restore
    /// owns no fans, so a plain one would skip them, report success and drop the marker with the fans still manual.
    private func revertLocked(reason: String) {
        guard !marker.exists else { forceRevertLocked(reason: reason); return }
        completeRevertLocked(reason: reason) { fans.restoreAll(reason: reason) }
    }

    private func forceRevertLocked(reason: String) {
        completeRevertLocked(reason: reason) { fans.forceRestoreAll(reason: reason) }
    }

    private func completeRevertLocked(reason: String, restore: () -> [String]) {
        let hadControl = fans.isControlling || overrideActive || marker.exists
        prepareRevert()
        let failures = restore()
        resetAfterRevert()
        updateRecoveryAfterRevert(reason: reason, failures: failures)
        if hadControl { recordRevert(reason: reason) }
    }

    private func prepareRevert() {
        overrideReleaseHoldUntil = nil
        lastHottestC = nil
    }

    private func resetAfterRevert() {
        leaseDeadline = nil
        overrideActive = false
        requestedRPM.removeAll()
        lastActivity = clock.now
    }

    private func updateRecoveryAfterRevert(reason: String, failures: [String]) {
        if failures.isEmpty {
            removeMarkerLocked()
            restoreRetryAt = nil
            return
        }
        restoreRetryAt = clock.now + .seconds(config.restoreRetrySeconds)
        serviceLog.error("restore (\(reason, privacy: .public)) incomplete: \(failures.joined(separator: "; "), privacy: .public)")
    }

    private func recordRevert(reason: String) {
        lastRevertReason = reason
        lastRevertDate = Date()
        serviceLog.notice("fans returned to System (\(reason, privacy: .public))")
    }

    private func writeMarkerLocked(owned: Set<Int>) throws {
        guard marker.path != nil else { return }
        let fanList = owned.sorted()
        let ftst = recoveryFtstLocked()
        // intelMinimumOnly: every original F%dMn not yet back in the SMC (empty on every other scheme).
        let minimums = minimumRecovery?.savedMinimumBytes ?? [:]
        if let w = writtenMarker, w.fans == fanList, w.ftst == ftst, w.minimums == minimums, marker.exists { return }
        let contents = Self.makeRecoveryMarker(fans: fanList, ftst: ftst, minimums: minimums)
        try marker.write(contents)
        writtenMarker = (fanList, ftst, minimums)
    }

    private func recoveryFtstLocked() -> Bool {
        // On Ftst hardware assume the unlock is ours: a recovery restore then also clears Ftst (I10 guaranteed
        // nobody else was forcing when Thermik took over).
        fans.ftstSetByUs || fans.profile.hasFtstKey
    }

    private static func makeRecoveryMarker(fans: [Int], ftst: Bool, minimums: [Int: [UInt8]]) -> RecoveryMarker {
        var contents = RecoveryMarker(pid: getpid(), ftstSetByUs: ftst, fans: fans, createdAt: Date())
        contents.savedMinimumBytes = minimums.isEmpty ? nil : minimums
        return contents
    }

    /// intelMinimumOnly (I7), called by the write layer between capturing fan `fan`'s original F%dMn and raising it:
    /// the original must be on disk first, or a crash right after the raise would lose it. Throwing aborts the raise.
    private func persistMinimumLocked(_ fan: Int) throws {
        do { try writeMarkerLocked(owned: fans.ownedFans.union([fan])) } catch {
            serviceLog.error("cannot write the recovery marker: \(error.localizedDescription, privacy: .public)")
            throw NSError.thermikHelper(.internalError, "cannot write the recovery marker")
        }
    }

    private func updateMarkerLocked() {
        guard fans.isControlling else { return }
        do { try writeMarkerLocked(owned: fans.ownedFans) }
        catch { serviceLog.error("cannot update the recovery marker: \(error.localizedDescription, privacy: .public)") }
    }

    private func removeMarkerLocked() {
        marker.remove()
        writtenMarker = nil
    }

    private func rateLimitLocked(_ t: Instant) -> NSError? {                                         // I11
        commandTimes.removeAll { t - $0 >= .seconds(1) }
        guard commandTimes.count < config.maxCommandsPerSecond else {
            return .thermikHelper(.rateLimited, "more than \(config.maxCommandsPerSecond) commands per second")
        }
        commandTimes.append(t)
        return nil
    }

    private func extendLeaseLocked(_ seconds: Double) {
        leaseDeadline = clock.now + .seconds(seconds)
    }

    private func infoLocked() -> HelperInfo {
        let v = HelperRuntime.version
        return HelperInfo(protocolVersion: ThermikHelper.protocolVersion, helperVersion: v.short, helperBuild: v.build,
                          pid: getpid(), installKind: installKind, fanCount: fans.profile.fans.count,
                          scheme: fans.profile.scheme.description)
    }

    private func stateLocked() -> HelperState {
        let now = clock.now
        let foreign = !fans.isControlling && !marker.exists && fans.foreignControlSuspected()
        return HelperState(info: infoLocked(), fans: fans.fanStates(), ftst: fans.ftstValue(), ftstSetByThermik: fans.ftstSetByUs,
                           isControlling: fans.isControlling,
                           leaseRemainingSeconds: leaseDeadline.map { max(0, Self.seconds($0 - now)) },
                           safetyOverrideActive: overrideActive, foreignControllerSuspected: foreign, sleeping: sleeping,
                           lastRevertReason: lastRevertReason, lastRevertDate: lastRevertDate)
    }

    // MARK: Helpers

    /// Lease clamped to [Limits.minLeaseSeconds, Limits.maxLeaseSeconds]; nil when not finite or not positive.
    static func clampedLease(_ s: Double) -> Double? {
        guard s.isFinite, s > 0 else { return nil }
        return min(max(s, ThermikHelper.Limits.minLeaseSeconds), ThermikHelper.Limits.maxLeaseSeconds)
    }

    /// Maps write-layer errors onto the wire codes (`HelperErrorCode`).
    static func wireError(_ error: any Error) -> NSError {
        if let e = error as? FanWriteError { return .thermikHelper(e.helperErrorCode, e.description) }
        if let e = error as? SMCError { return .thermikHelper(.hardwareFailure, "\(e)") }
        let ns = error as NSError
        if ns.domain == ThermikHelper.errorDomain { return ns }
        return .thermikHelper(.hardwareFailure, ns.localizedDescription)
    }

    private static func replyEncoded<T: Encodable>(_ value: T, _ reply: @Sendable (Data?, NSError?) -> Void) {
        do { reply(try HelperWire.encode(value), nil) }
        catch { reply(nil, .thermikHelper(.internalError, "cannot encode the reply: \(error)")) }
    }

    private static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
