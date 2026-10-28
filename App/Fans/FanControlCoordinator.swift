// FanControlCoordinator.swift — Thermik (MIT). OWNER: Unit 3. The app → helper command pipeline behind FanStore
// (SPEC §2.9.4 steps 5–6): sends only CHANGES, one sequence in flight at a time with "latest desired state wins",
// renews the lease every 2 s while Thermik holds the fans, releases everything with one `resetAllFans()`, and
// classifies helper errors for FanStore's policy (retry, monitoring-only, foreign controller, …).
// Port of the FANS draft's `FanHelperClient.flush` / heartbeat logic onto the async `FanHelperClient` protocol.
//
// The lease is renewed only while FanStore's engine is alive (`apply` called within `maxEngineSilence`): if the
// ticks stall (a hung sampler) the helper's I3 lease runs out and macOS gets the fans back instead of a stale speed.
// An error back-off still lets a safety raise of a fan Thermik holds through. After a lost lease nothing is
// re-sent until FanStore has read the helper's revert reason (`resumeAfterLeaseLoss()`), so a helper safety revert
// never turns into an engage → revert loop.
//
// Concurrency: main actor. XPC calls run off-main inside the client; every reply hops back here. A `generation`
// counter invalidates replies of sequences that a release, a lost lease or a reconnect superseded, so a late
// reply can never resurrect state (the helper's serial queue applies the calls in the order sent).
import Foundation
import os
import ThermikCore
import ThermikHelperShared

/// A failed helper call, classified per the SPEC §2.9.4 error table.
enum FanCommandFailure: Equatable, Sendable {
    case unlockTimeout(String)          // Ftst unlock not accepted (or a reclaimed fan re-asserted too soon)
    case foreignController              // the helper refuses: another app forces the fans (I10)
    case safetyOverride                 // the helper holds every fan at max (I8)
    case sleeping                       // the system is going to / coming back from sleep
    case rateLimited
    case unavailable(String)            // notPermitted, protocol mismatch, connection invalid, code-signing failure
    case interrupted                    // the helper restarted: it restored System; re-send
    case notControllable(String)
    case failed(String)

    init(_ error: Error) {
        let ns = error as NSError
        let detail = ns.localizedDescription
        if let code = ns.thermikHelperCode {
            switch code {
            case .unlockTimeout: self = .unlockTimeout(detail)
            case .foreignController: self = .foreignController
            case .safetyOverride: self = .safetyOverride
            case .sleeping: self = .sleeping
            case .rateLimited: self = .rateLimited
            case .notPermitted, .unsupportedProtocol: self = .unavailable(detail)
            case .notControllable, .fanNotFound: self = .notControllable(detail)
            case .invalidArgument, .hardwareFailure, .internalError, .verificationFailed: self = .failed(detail)
            }
        } else if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSXPCConnectionInterrupted: self = .interrupted
            case NSXPCConnectionInvalid, NSXPCConnectionCodeSigningRequirementFailure: self = .unavailable(detail)
            default: self = .failed(detail)
            }
        } else {
            self = .failed(detail)
        }
    }
}

@MainActor final class FanControlCoordinator {
    enum Phase: Equatable, Sendable {
        case idle        // nothing held (macOS in charge)
        case engaging    // first manual command in flight (the M3/M4 Ftst unlock may take ≤ 12 s)
        case engaged     // Thermik holds at least one fan (◆ badge); the lease is renewed
    }

    static let leaseSeconds = ThermikHelper.Limits.defaultLeaseSeconds
    static let renewInterval: Duration = .seconds(ThermikHelper.Limits.heartbeatSeconds)
    /// No `apply` (engine tick) for this long: the engine is stalled, renewals stop (≈ 5 ticks at the 1 Hz cadence).
    static let maxEngineSilence: TimeInterval = 5
    /// After a lost lease, nothing is re-sent until FanStore decided, or at most this long.
    static let leaseDecisionTimeout: TimeInterval = 3
    /// Thermik's helper may still force the fans this long after the app's last command or renewal (the lease, plus
    /// the helper's 1 Hz watchdog and the SMC read-back lag).
    static let helperHoldSeconds: TimeInterval = leaseSeconds + 2

    private let helper: HelperManager
    private let logger = Logger(subsystem: "app.thermik.Thermik", category: "fans")

    private(set) var phase: Phase = .idle
    /// Commands the helper confirmed (requested values, so a clamp in the helper never causes a resend loop).
    private(set) var lastSent: [Int: FanCommand] = [:]
    /// rpm the helper reports it actually wrote.
    private(set) var appliedRPM: [Int: Double] = [:]
    /// When Thermik last released the fans (FanStore ignores forcing briefly afterwards: the SMC lags ~250 ms).
    private(set) var lastReleaseAt: Date?
    /// When the helper last confirmed a command (its targets are in the SMC from then on).
    private(set) var lastCommandAt: Date?
    private(set) var isSleeping = false
    private var desired: [Int: FanCommand] = [:]
    /// The desired state comes from a safety reaction (engine latch, thermal guard): it may bypass an error back-off.
    private var desiredIsSafety = false
    private var inFlight = false
    private var generation = 0
    /// Nothing is sent before this (rate limit, sleep, helper safety override, helper unavailable).
    private var suspendedUntil: Date?
    /// Error back-off (failed command, refused unlock): only safety raises of fans Thermik holds are sent.
    private var backoffUntil: Date?
    /// Lost lease: nothing is re-sent before FanStore decided (or this deadline passes).
    private var leaseDecisionUntil: Date?
    private var leaseTask: Task<Void, Never>?
    /// Last `apply` (the engine ran) and last successful lease extension (command or renewal).
    private var lastApplyAt: Date?
    private var lastLeaseExtendedAt: Date?
    private var stallLogged = false
    /// Until then Thermik's helper may still force the fans. Starts one hold after launch: a previous instance that
    /// crashed may still hold them until its lease runs out.
    private var helperMayHoldUntil = Date().addingTimeInterval(FanControlCoordinator.helperHoldSeconds)

    /// Phase changed (FanStore recomputes status / ◆ badge).
    var onStateChange: () -> Void = {}
    /// A command or renewal succeeded.
    var onSuccess: () -> Void = {}
    /// A helper call failed (classified). Transport-level reactions (forget state, refresh) already happened.
    var onFailure: (FanCommandFailure) -> Void = { _ in }
    /// `renewLease` replied false: the helper reverted (sleep, lease, safety, macOS reclaimed a fan), or the lease ran
    /// out while the engine was stalled. Nothing is re-sent until FanStore calls `resumeAfterLeaseLoss()` (≤ 3 s).
    var onLeaseLost: () -> Void = {}

    init(helper: HelperManager) { self.helper = helper }

    var isOverriding: Bool { phase == .engaged }
    var isEngaging: Bool { phase == .engaging }
    /// Thermik may hold the fans right now (engaged, or a command is in flight).
    var mayHoldFans: Bool { phase != .idle || inFlight }
    /// A command sequence is in flight (the SMC targets are changing).
    var hasCommandInFlight: Bool { inFlight }

    /// Forcing seen in the SMC may be Thermik's own: Thermik holds the fans, or did within one lease (I3) — a lost
    /// reply, the other fans after a macOS reclaim, a previous instance at launch, the SMC catching up on a release.
    func helperMayHoldFans(now: Date) -> Bool { mayHoldFans || now < helperMayHoldUntil }

    // MARK: Commands

    /// Desired state for every fan, once per engine tick (this is also the engine's heartbeat for the lease). Only
    /// differences are sent, sequentially; the latest desired state wins. `safety`: the commands come from the
    /// engine's safety latch or thermal guard, so raises of fans Thermik holds bypass an error back-off.
    func apply(_ commands: [Int: FanCommand], now: Date = Date(), safety: Bool = false) {
        desired = commands
        desiredIsSafety = safety
        lastApplyAt = now
        if stallLogged { stallLogged = false; logger.notice("fan engine ticking again") }
        flush(now: now)
    }

    /// No new commands before `date` (rate limit, sleep, helper safety override). Lease renewals continue.
    func suspend(until date: Date) {
        suspendedUntil = max(suspendedUntil ?? date, date)
    }

    /// Error back-off: no new commands before `date`, except safety raises of fans Thermik already holds (a safety
    /// latch must not wait out a retry delay at a low speed). Lease renewals continue.
    func backOff(until date: Date) {
        backoffUntil = max(backoffUntil ?? date, date)
    }

    /// FanStore read the revert reason after a lost lease and wants Thermik's targets back: the next tick re-sends.
    func resumeAfterLeaseLoss() {
        leaseDecisionUntil = nil
    }

    /// Every fan back to System with one idempotent `resetAllFans()`. Optimistic: the badge clears at once (the
    /// helper restores within milliseconds; if the call fails the lease restores within 10 s anyway).
    func releaseAll(reason: String) {
        generation += 1
        let gen = generation
        let wasHolding = mayHoldFans
        inFlight = false
        leaseDecisionUntil = nil
        lastSent = desired.isEmpty ? [:] : desired.mapValues { _ in .system }
        appliedRPM.removeAll()
        stopLease()
        lastReleaseAt = Date()
        if phase != .idle { phase = .idle; onStateChange() }
        if wasHolding { logger.notice("releasing all fans (\(reason))") }
        let client = helper.client
        Task { @MainActor in
            do {
                try await client.resetAllFans()
            } catch {
                guard gen == self.generation else { return }
                self.handle(FanCommandFailure(error))
            }
        }
    }

    /// Forget what was sent so the next tick re-sends everything (helper reverted or restarted, wake, reconnect).
    func forgetSentState() {
        generation += 1
        inFlight = false
        lastSent.removeAll()
        appliedRPM.removeAll()
        stopLease()
        if phase != .idle { phase = .idle; onStateChange() }
    }

    /// Belt and braces: the helper itself restores before sleep (I6). No commands until `systemDidWake()`.
    func systemWillSleep() {
        releaseAll(reason: "sleep")
        isSleeping = true
    }

    /// Called by FanStore 3 s after wake: start from scratch; the next tick re-applies the mode.
    func systemDidWake() {
        isSleeping = false
        suspendedUntil = nil
        backoffUntil = nil
        leaseDecisionUntil = nil
        forgetSentState()
    }

    /// applicationWillTerminate: bounded synchronous restore.
    func resetAllBlocking(timeout: TimeInterval) {
        generation += 1
        inFlight = false
        stopLease()
        helper.client.resetAllFansBlocking(timeout: timeout)
        lastSent.removeAll()
        appliedRPM.removeAll()
        phase = .idle
    }

    // MARK: Pipeline

    private func flush(now: Date) {
        guard !isSleeping, !inFlight else { return }
        if let until = suspendedUntil {
            guard now >= until else { return }
            suspendedUntil = nil
        }
        if desired.values.allSatisfy({ $0 == .system }) {                // releasing is always allowed
            if mayHoldFans { releaseAll(reason: "all fans System") } else { lastSent = desired }
            return
        }
        if let until = leaseDecisionUntil {
            guard now >= until else { return }
            leaseDecisionUntil = nil
            logger.notice("no decision after the lost lease; re-sending")
        }
        var changes = desired.filter { lastSent[$0.key] != $0.value }.sorted { $0.key < $1.key }
        if let until = backoffUntil {
            if now >= until {
                backoffUntil = nil
            } else {
                guard desiredIsSafety else { return }
                changes = changes.filter { Self.isRaise($0.value, over: lastSent[$0.key]) }
            }
        }
        guard !changes.isEmpty else { return }
        inFlight = true
        if phase == .idle { phase = .engaging; onStateChange() }
        let gen = generation
        let client = helper.client
        let items = changes.map { (fan: $0.key, command: $0.value) }
        Task { @MainActor in await self.send(items, client: client, generation: gen) }
    }

    /// A higher rpm for a fan Thermik already holds (a new engagement is not: it is what a back-off protects).
    private static func isRaise(_ command: FanCommand, over last: FanCommand?) -> Bool {
        guard case .rpm(let new) = command, case .rpm(let old)? = last else { return false }
        return new > old
    }

    private func send(_ items: [(fan: Int, command: FanCommand)], client: any FanHelperClient, generation gen: Int) async {
        for item in items {
            do {
                switch item.command {
                case .rpm(let rpm):
                    helperMayHoldUntil = Date().addingTimeInterval(Self.helperHoldSeconds)
                    let applied = try await client.setFanTarget(item.fan, rpm: rpm, leaseSeconds: Self.leaseSeconds)
                    guard gen == generation else { return }              // superseded: a release already reset us
                    lastSent[item.fan] = item.command
                    appliedRPM[item.fan] = applied
                    lastLeaseExtendedAt = Date()
                    if phase != .engaged {
                        phase = .engaged
                        startLease()
                        logger.notice("fan control engaged (fan \(item.fan, privacy: .public) at \(Int(applied), privacy: .public) rpm)")
                        onStateChange()
                    }
                case .system:
                    try await client.setFanAutomatic(item.fan)
                    guard gen == generation else { return }
                    lastSent[item.fan] = .system
                    appliedRPM[item.fan] = nil
                }
                lastCommandAt = Date()
                onSuccess()
            } catch {
                guard gen == generation else { return }
                inFlight = false
                if phase == .engaging, !lastSent.values.contains(where: { $0 != .system }) { phase = .idle; onStateChange() }
                handle(FanCommandFailure(error))
                return
            }
        }
        guard gen == generation else { return }
        inFlight = false
        if phase != .idle, !lastSent.values.contains(where: { $0 != .system }) {
            phase = .idle; stopLease(); lastReleaseAt = Date(); onStateChange()
        }
        flush(now: Date())                                               // desired may have changed meanwhile
    }

    // MARK: Lease (I3: the helper reverts after `leaseSeconds` without a command or renewal)

    private func startLease() {
        leaseTask?.cancel()
        leaseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.renewInterval)
                guard let self, !Task.isCancelled, self.phase == .engaged else { return }
                if self.engineStalled(now: Date()) { self.leaseStalled(); continue }
                await self.renewOnce()
            }
        }
    }

    /// The lease stands for "the engine still controls these fans": no tick for `maxEngineSilence` (a hung sampler
    /// stops the ticks while the main actor stays free) means no renewal.
    private func engineStalled(now: Date) -> Bool {
        lastApplyAt.map { now.timeIntervalSince($0) > Self.maxEngineSilence } ?? true
    }

    /// Stalled engine: let the lease run out so the helper returns the fans to System (I3). Once it surely has (its
    /// watchdog runs at 1 Hz), forget what was sent: the first tick after the stall re-sends everything (handled like
    /// any lost lease).
    private func leaseStalled() {
        if !stallLogged {
            stallLogged = true
            logger.error("no fan engine tick for \(Self.maxEngineSilence, privacy: .public) s: lease not renewed (the helper returns the fans to System)")
        }
        guard let extended = lastLeaseExtendedAt, Date().timeIntervalSince(extended) > Self.helperHoldSeconds else { return }
        logger.notice("lease ran out while the fan engine was stalled")
        leaseWasLost()
    }

    /// The helper no longer holds what Thermik sent. Hold every re-send until FanStore read why (bounded).
    private func leaseWasLost() {
        forgetSentState()
        leaseDecisionUntil = Date().addingTimeInterval(Self.leaseDecisionTimeout)
        onLeaseLost()
    }

    private func stopLease() {
        leaseTask?.cancel()
        leaseTask = nil
    }

    private func renewOnce() async {
        let gen = generation
        let client = helper.client
        helperMayHoldUntil = Date().addingTimeInterval(Self.helperHoldSeconds)
        do {
            let stillControlling = try await client.renewLease(seconds: Self.leaseSeconds)
            guard gen == generation, phase == .engaged else { return }
            if stillControlling { lastLeaseExtendedAt = Date(); return }
            logger.notice("helper no longer controls the fans (reverted or macOS reclaimed a fan)")
            leaseWasLost()
        } catch {
            guard gen == generation else { return }
            handle(FanCommandFailure(error))
        }
    }

    // MARK: Errors (transport-level part; FanStore owns the policy)

    private func handle(_ failure: FanCommandFailure) {
        switch failure {
        case .interrupted:
            forgetSentState()                                            // the restarted helper restored System
        case .unavailable:
            forgetSentState()
            suspend(until: Date().addingTimeInterval(5))                 // do not hammer a helper that refuses us
            Task { @MainActor [helper] in await helper.refresh() }       // → monitoring-only until it is ready again
        case .rateLimited:
            suspend(until: Date().addingTimeInterval(1))                 // drop this tick
        case .sleeping:
            suspend(until: Date().addingTimeInterval(3))                 // the wake path re-applies
        case .unlockTimeout, .foreignController, .safetyOverride, .notControllable, .failed:
            break
        }
        logger.error("fan command failed: \(String(describing: failure))")
        onFailure(failure)
    }
}
