// FanWriteSequencer.swift — Thermik (MIT). HELPER ONLY (this module is linked by thermik-helper and, for the
// offline simulator against FakeSMC, by thermik-probe; never by the app).
//
// The only code in Thermik that writes to the SMC. Responsibilities:
//   * key allow-list (mode keys, F%dTg, Ftst, FS!, and F%dMn on min-only Intel) — invariant I2
//   * per-scheme "enter manual" sequence, incl. the M3/M4 Ftst unlock
//   * clamping every target to [F%dMn, F%dMx] — invariant I1
//   * best-effort, never-throwing restore of System mode
//   * min-only Intel: the original F%dMn survives a failed restore and a crash (`MinimumOnlyRecovery`, I7)
//
// Port of research/fans/code/HelperOnly/FanWriteSequencer.swift (SPEC §2.6.3); the min-only recovery is new. The
// research `#if THERMIK_HELPER` guard is gone: the file simply lives in the helper-only module.
//
// Not thread-safe by design: the owner (SMCFanController, driven by HelperService) calls it only from the
// helper's single serial state queue.
//
// Sequence facts (public sources, FANS §5): agoodkind/macos-smc-fan (MIT), exelban/Stats SMC/smc.swift (MIT),
// raminsharifi/MacFanControl (MIT), estevecastells/macfanoptimizer (MIT), smcFanControl & Linux applesmc
// (GPL; facts only). Independent implementation.
import Foundation
import os
import ThermikSMC

/// Injectable clock so the sequence can be simulated without real sleeps (`thermik-probe fans sim`).
public protocol SequencerClock: AnyObject {
    func now() -> Date
    func sleep(_ seconds: Double)
}

/// Wall clock + blocking sleep (the helper's state queue may block: the M3/M4 unlock takes 3–6 s).
public final class SystemSequencerClock: SequencerClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(_ seconds: Double) { if seconds > 0 { Thread.sleep(forTimeInterval: seconds) } }
}

public struct FanWriteTiming: Sendable, Equatable {
    /// Wait after Ftst=1 before the first mode retry. Observed unlock latency on M4:
    /// mode 3 -> 0 after 3–4 s, mode write accepted after 4–6 s (agoodkind).
    public var settleAfterFtst: Double = 1.0
    public var retryInterval: Double = 0.1
    /// Give up on the unlock after this long (agoodkind: 10 s; Stats waits up to ~33 s).
    public var unlockDeadline: Double = 12
    /// Writes become readable only after ~250 ms (triuzzi/macos-fan-control).
    public var readBackDelay: Double = 0.3
    /// After a *direct* mode write on Ftst hardware, re-check that the OS did not
    /// immediately reclaim the fan; if it did, escalate to the Ftst path.
    public var stickCheckDelay: Double = 1.5
    /// Never re-assert manual mode on the same fan more often than this:
    /// hammering the mode key can push the SMC into a refusing state (fanctl, M4 Pro).
    public var minReassertInterval: Double = 5
    /// Retries for restore writes.
    public var restoreAttempts: Int = 3
    public var restoreRetryDelay: Double = 0.05
    /// Handing a stopped fan back: how long the mode write may be retried while the fan spins up to its minimum
    /// (M4 Max: accepted 6.1 s and 7.3 s after the new target), and how often (gently: hammering the mode key is not
    /// harmless, see above).
    public var releaseSpinUpDeadline: Double = 12
    public var releaseSpinUpRetryInterval: Double = 0.5
    public init() {}
}

/// intelMinimumOnly crash recovery (I7). On such a Mac Thermik "forces" a fan by raising F%dMn, so giving it back to
/// System means writing the ORIGINAL F%dMn bytes back, and those must outlive a helper crash or a failed restore:
/// HelperService keeps them in the recovery marker. An optional companion of the `FanControlling` contract
/// (FanWriteSequencer and SMCFanController conform; the mock and the "no SMC" controller need not).
public protocol MinimumOnlyRecovery: AnyObject {
    /// Original F%dMn bytes per fan index that are not back in the SMC yet (always empty on every other scheme).
    var savedMinimumBytes: [Int: [UInt8]] { get }
    /// Called with the fan index after its original F%dMn was captured (already in `savedMinimumBytes`) and BEFORE
    /// the first raised value is written. Throwing aborts that write; the minimum stays untouched.
    var willRaiseMinimum: ((Int) throws -> Void)? { get set }
    /// Originals from a crashed instance's recovery marker; the next forced restore writes them back.
    func adoptSavedMinimumBytes(_ bytes: [Int: [UInt8]])
}

public final class FanWriteSequencer: MinimumOnlyRecovery {
    private let smc: any SMCReadWriting
    public let profile: FanHardwareProfile
    public let clock: any SequencerClock
    public var timing: FanWriteTiming
    public var log: (String) -> Void

    /// Fans currently forced by Thermik.
    public private(set) var ownedFans: Set<Int> = []
    /// True if Thermik wrote Ftst=1 (so Thermik must write Ftst=0 later).
    public private(set) var ftstSetByUs = false
    /// A direct mode write already survived the stick check while Thermik still holds a fan. The mechanism is the
    /// same for every fan of this Mac, so the next fan skips the 1.5 s wait (it started ~2 s after the first one).
    /// A later reclaim is still caught by `ensureManual`'s owned-but-not-manual check.
    private var directWriteSticks = false
    /// Last clamped target written per fan.
    public private(set) var appliedRPM: [Int: Double] = [:]
    /// The only keys this sequencer will ever write (I2). Built once from the discovered profile.
    public let allowList: Set<FourCC>
    /// intelMinimumOnly: original F%dMn bytes to restore. A fan's entry is dropped only after its restore write
    /// succeeded, so a failed restore can still be retried (`MinimumOnlyRecovery`).
    public private(set) var savedMinimumBytes: [Int: [UInt8]] = [:]
    /// intelMinimumOnly: persistence hook, see `MinimumOnlyRecovery.willRaiseMinimum`.
    public var willRaiseMinimum: ((Int) throws -> Void)?
    private var lastManualAssert: [Int: Date] = [:]
    /// Stopped fans given their minimum so they can be handed back, and since when (see `releaseMode`).
    private var spinUpStartedAt: [Int: Date] = [:]

    public var isControlling: Bool { !ownedFans.isEmpty || ftstSetByUs }

    private static let logger = Logger(subsystem: "app.thermik.helper", category: "fans")
    /// Default sink: transitions at `.notice` in the helper's unified log.
    public static let defaultLog: @Sendable (String) -> Void = { message in logger.notice("\(message, privacy: .public)") }

    public init(smc: any SMCReadWriting, profile: FanHardwareProfile, clock: any SequencerClock = SystemSequencerClock(),
                timing: FanWriteTiming = FanWriteTiming(), log: @escaping (String) -> Void = FanWriteSequencer.defaultLog) {
        self.smc = smc; self.profile = profile; self.clock = clock; self.timing = timing; self.log = log
        var keys: Set<FourCC> = []
        for f in profile.fans {
            if profile.scheme == .intelMinimumOnly { keys.insert(.fan("F%dMn", f.index)) }
            else { keys.insert(.fan("F%dTg", f.index)) }
            if let m = f.modeKey { keys.insert(m) }
        }
        switch profile.scheme {
        case .appleSilicon(_, let hasFtst): if hasFtst { keys.insert(FanHardwareProfile.ftstKey) }
        case .intelModeKey, .intelForceBits:
            if (try? smc.keyInfo(FanHardwareProfile.forceBitsKey)) != nil { keys.insert(FanHardwareProfile.forceBitsKey) }
        default: break
        }
        allowList = keys
    }

    /// Restores bookkeeping after a helper restart (from the recovery marker).
    public func adoptPersistedState(ftstSetByUs: Bool) { self.ftstSetByUs = ftstSetByUs }

    /// intelMinimumOnly: originals from a crashed instance's recovery marker. Taken only for fans of this profile
    /// whose bytes have the key's exact size and decode to a plausible minimum (0 ≤ rpm < F%dMx), never over an
    /// original this instance captured itself, and not when F%dMn already holds them (nothing was raised yet).
    public func adoptSavedMinimumBytes(_ bytes: [Int: [UInt8]]) {
        guard profile.scheme == .intelMinimumOnly else { return }
        for (index, original) in bytes.sorted(by: { $0.key < $1.key }) where savedMinimumBytes[index] == nil {
            adoptSavedMinimum(index, original: original)
        }
    }

    private func adoptSavedMinimum(_ index: Int, original: [UInt8]) {
        let key = FourCC.fan("F%dMn", index)
        guard let rpm = recoveredMinimumRPM(index, original: original, key: key) else {
            log("fan \(index): ignoring the recovered F\(index)Mn bytes \(original)")
            return
        }
        if let current = try? smc.readRaw(key).1, current == original { return }
        savedMinimumBytes[index] = original
        log(String(format: "fan %d: original F%dMn %.0f rpm recovered from the marker", index, index, rpm))
    }

    private func recoveredMinimumRPM(_ index: Int, original: [UInt8], key: FourCC) -> Double? {
        guard let fan = profile.fan(index), let info = try? smc.keyInfo(key),
              original.count == Int(info.size), let rpm = SMCCodec.decode(original, as: info).doubleValue,
              rpm.isFinite, rpm >= 0, rpm < fan.maxRPM else { return nil }
        return rpm
    }

    // MARK: - Low-level guarded I/O

    private func write(_ key: FourCC, _ bytes: [UInt8]) throws {
        guard allowList.contains(key) else { throw FanWriteError.notAllowed(key) }   // defence in depth (I2)
        do { try smc.writeRaw(key, bytes) } catch let e as SMCError { throw FanWriteError.smc(e) }
    }

    private func writeUInt8(_ key: FourCC, _ v: UInt8) throws {
        let info: SMCKeyInfo
        do { info = try smc.keyInfo(key) } catch let e as SMCError { throw FanWriteError.smc(e) }
        let bytes: [UInt8]
        do { bytes = try SMCCodec.encodeUInt8(v, as: info, key: key) } catch let e as SMCError { throw FanWriteError.smc(e) }
        try write(key, bytes)
    }

    private func readUInt8(_ key: FourCC) -> UInt8? { try? smc.readUInt8(key) }

    private func descriptor(_ index: Int) throws -> FanDescriptor {
        guard let f = profile.fan(index) else { throw FanWriteError.invalidFan(index) }
        return f
    }

    // MARK: - Enter manual

    /// Idempotent. On M3/M4 may block for several seconds (Ftst unlock).
    public func ensureManual(_ index: Int) throws { try ensureManual(index, onManual: nil) }

    /// `onManual` runs as soon as a direct mode write reads back as manual, before the 1.5 s stick check: it writes
    /// the target, so the fan already ramps (a safety override must not wait out the check at the old speed).
    private func ensureManual(_ index: Int, onManual: (() throws -> Void)?) throws {
        let fan = try descriptor(index)
        switch profile.scheme {
        case .none: throw FanWriteError.notControllable
        case .appleSilicon(_, let hasFtst): try ensureManualAppleSilicon(fan, hasFtst: hasFtst, onManual: onManual)
        case .intelModeKey: try ensureManualIntelMode(fan)
        case .intelForceBits: try setForceBit(fan.index)
        case .intelMinimumOnly: try prepareMinimum(fan.index)
        }
        ownedFans.insert(fan.index)
    }

    private func ensureManualAppleSilicon(_ fan: FanDescriptor, hasFtst: Bool, onManual: (() throws -> Void)?) throws {
        guard let modeKey = fan.modeKey else { throw FanWriteError.notControllable }
        let index = fan.index
        if ownedFans.contains(index), readUInt8(modeKey) == 1 { return }
        try reassertAppleSilicon(index)
        lastManualAssert[index] = clock.now()
        try enterManualAppleSilicon(index: index, modeKey: modeKey, hasFtst: hasFtst, onManual: onManual)
    }

    private func reassertAppleSilicon(_ index: Int) throws {
        guard ownedFans.contains(index) else { return }
        // We owned it but macOS took it back (wake, thermal reclaim). Throttle re-asserts.
        if let last = lastManualAssert[index], clock.now().timeIntervalSince(last) < timing.minReassertInterval {
            throw FanWriteError.reclaimedTooSoon(fan: index)
        }
        ownedFans.remove(index)
    }

    private func ensureManualIntelMode(_ fan: FanDescriptor) throws {
        guard let modeKey = fan.modeKey else { throw FanWriteError.notControllable }
        if readUInt8(modeKey) != 1 { try writeUInt8(modeKey, 1) }
        if allowList.contains(FanHardwareProfile.forceBitsKey) { try setForceBit(fan.index) }
    }

    private func prepareMinimum(_ index: Int) throws {
        guard savedMinimumBytes[index] == nil else { return }
        do { savedMinimumBytes[index] = try smc.readRaw(.fan("F%dMn", index)).1 } catch let e as SMCError { throw FanWriteError.smc(e) }
        // I7: the original reaches the recovery marker before anything raises it.
        do { try willRaiseMinimum?(index) } catch { savedMinimumBytes[index] = nil; throw error }
    }

    private func enterManualAppleSilicon(index: Int, modeKey: FourCC, hasFtst: Bool, onManual: (() throws -> Void)?) throws {
        // Phase 1: direct write (M1/M2/M5, and M3/M4 when the OS is not asserting mode 3).
        if let lastError = attemptDirectManual(index: index, modeKey: modeKey, hasFtst: hasFtst, onManual: onManual) {
            guard hasFtst else {
                throw FanWriteError.unlockTimeout(fan: index, elapsed: 0, lastError: lastError)
            }
            try enterManualUsingFtst(index: index, modeKey: modeKey, initialError: lastError)
        }
    }

    private func attemptDirectManual(index: Int, modeKey: FourCC, hasFtst: Bool, onManual: (() throws -> Void)?) -> String? {
        do {
            try writeUInt8(modeKey, 1)
            clock.sleep(timing.readBackDelay)
            guard readUInt8(modeKey) == 1 else { return "direct write not reflected in read-back" }
            if directManualAlreadyEffective(index, hasFtst: hasFtst) { return nil }
            return checkDirectManualStick(index, modeKey: modeKey, onManual: onManual)
        } catch {
            return "\(error)"     // typically SMC 0x82 (kSMCBadCommand) while macOS holds mode 3
        }
    }

    private func directManualAlreadyEffective(_ index: Int, hasFtst: Bool) -> Bool {
        // No Ftst on this Mac, or Ftst already 1 (unlock in effect): nothing to escalate to / no reclaim risk.
        if !hasFtst || readUInt8(FanHardwareProfile.ftstKey) == 1 { log("fan \(index): manual via direct write"); return true }
        if directWriteSticks && !ownedFans.isEmpty { log("fan \(index): manual via direct write (sticky earlier)"); return true }
        return false
    }

    private func checkDirectManualStick(_ index: Int, modeKey: FourCC, onManual: (() throws -> Void)?) -> String? {
        try? onManual?()                       // ramp during the check; setTarget writes the target again after it
        clock.sleep(timing.stickCheckDelay)
        guard readUInt8(modeKey) == 1 else { return "direct write reclaimed by macOS" }
        directWriteSticks = true
        log("fan \(index): manual via direct write (sticky)")
        return nil
    }

    private func enterManualUsingFtst(index: Int, modeKey: FourCC, initialError: String) throws {
        // Phase 2: Ftst unlock (M3/M4). Ftst is global; set it once.
        let start = clock.now()
        try prepareFtstForUnlock()
        if let lastError = waitForFtstUnlock(index: index, modeKey: modeKey, start: start, initialError: initialError) {
            // Failed: do not leave Ftst=1 behind if nothing else needs it.
            if ownedFans.isEmpty && ftstSetByUs { clearFtstBestEffort() }
            throw FanWriteError.unlockTimeout(fan: index, elapsed: clock.now().timeIntervalSince(start), lastError: lastError)
        }
    }

    private func prepareFtstForUnlock() throws {
        let ftst = FanHardwareProfile.ftstKey
        guard readUInt8(ftst) != 1 else { return }
        ftstSetByUs = true                         // set first: clearing an already-0 Ftst later is harmless
        try writeUInt8(ftst, 1)
        log("Ftst=1 written; waiting for thermalmonitord to yield")
        clock.sleep(timing.settleAfterFtst)
    }

    private func waitForFtstUnlock(index: Int, modeKey: FourCC, start: Date, initialError: String) -> String? {
        var lastError = initialError
        while clock.now().timeIntervalSince(start) < timing.unlockDeadline {
            guard let error = attemptFtstModeWrite(modeKey) else {
                log(String(format: "fan %d: manual via Ftst unlock after %.2fs", index, clock.now().timeIntervalSince(start)))
                return nil
            }
            lastError = error
            clock.sleep(timing.retryInterval)
        }
        return lastError
    }

    private func attemptFtstModeWrite(_ modeKey: FourCC) -> String? {
        do {
            try writeUInt8(modeKey, 1)
            clock.sleep(timing.readBackDelay)
            return readUInt8(modeKey) == 1 ? nil : "mode write accepted but not reflected"
        } catch {
            return "\(error)"
        }
    }

    private func setForceBit(_ index: Int) throws {
        try updateForceBit(index) { current, bit in current | bit }
    }

    private func clearForceBit(_ index: Int) throws {
        try updateForceBit(index) { current, bit in current & ~bit }
    }

    private func updateForceBit(_ index: Int, transform: (UInt16, UInt16) -> UInt16) throws {
        let key = FanHardwareProfile.forceBitsKey
        let raw: [UInt8]
        do { raw = try smc.readRaw(key).1 } catch let e as SMCError { throw FanWriteError.smc(e) }
        guard raw.count >= 2 else { throw FanWriteError.smc(.sizeMismatch(key: key, expected: 2, actual: raw.count)) }
        let current = UInt16(raw[0]) << 8 | UInt16(raw[1])             // big-endian bitmask
        let bit = UInt16(1) << UInt16(index)
        let new = transform(current, bit)
        if new != current { try write(key, [UInt8(new >> 8), UInt8(new & 0xFF)]) }
    }

    // MARK: - Target

    /// Clamps, encodes per key type, writes, and returns the RPM actually written.
    @discardableResult
    public func setTarget(_ index: Int, rpm requested: Double) throws -> Double {
        let fan = try descriptor(index)
        let rpm = try clampedTarget(fan, requested: requested)
        let earlyTarget = earlyTargetWriter(index, rpm: rpm)
        try ensureManual(index, onManual: earlyTarget)
        try writeTarget(index, rpm: rpm)
        return rpm
    }

    private func clampedTarget(_ fan: FanDescriptor, requested: Double) throws -> Double {
        guard requested.isFinite, requested >= 0 else { throw FanWriteError.smc(.invalidValue("rpm \(requested)")) }
        // I1: the SMC does no sanity checks. Exactly 0 is a stop where the hardware has one (the helper decides when).
        return requested == 0 && profile.scheme.allowsFanStop ? 0 : fan.clamp(requested).rounded()
    }

    /// Early target write for the stick check (Apple Silicon direct path); encoding problems surface below.
    private func earlyTargetWriter(_ index: Int, rpm: Double) -> (() throws -> Void)? {
        guard profile.scheme != .intelMinimumOnly else { return nil }
        return { [self] in
            let key = FourCC.fan("F%dTg", index)
            try self.write(key, try SMCCodec.encodeRPM(rpm, as: try smc.keyInfo(key), key: key))
        }
    }

    private func writeTarget(_ index: Int, rpm: Double) throws {
        if profile.scheme == .intelMinimumOnly {
            try writeMinimumTarget(index, rpm: rpm)
            return
        }
        try writeStandardTarget(index, rpm: rpm)
    }

    private func writeMinimumTarget(_ index: Int, rpm: Double) throws {
        let key = FourCC.fan("F%dMn", index)
        let bytes = try encodedTarget(key, rpm: rpm)
        try write(key, bytes)
        appliedRPM[index] = rpm
    }

    private func encodedTarget(_ key: FourCC, rpm: Double) throws -> [UInt8] {
        let info: SMCKeyInfo
        do { info = try smc.keyInfo(key) } catch let e as SMCError { throw FanWriteError.smc(e) }
        do { return try SMCCodec.encodeRPM(rpm, as: info, key: key) } catch let e as SMCError { throw FanWriteError.smc(e) }
    }

    private func writeStandardTarget(_ index: Int, rpm: Double) throws {
        let key = FourCC.fan("F%dTg", index)
        let bytes = try encodedTarget(key, rpm: rpm)
        do {
            try write(key, bytes)
        } catch FanWriteError.smc(.firmware(SMCResultCode.keySizeMismatch.rawValue, _)) {
            try verifyTargetAfterSizeMismatch(key, rpm: rpm)
        }
        appliedRPM[index] = rpm
        spinUpStartedAt[index] = nil
    }

    private func verifyTargetAfterSizeMismatch(_ key: FourCC, rpm: Double) throws {
        // kSMCKeySizeMismatch (0x87): observed on F0Tg with the value applied anyway (agoodkind). Verify.
        clock.sleep(timing.readBackDelay)
        let back = (try? smc.readNumber(key)) ?? -1
        guard abs(back - rpm) < 1 else {
            throw FanWriteError.verificationFailed(key: key, expected: "\(rpm)", actual: "\(back)")
        }
    }

    // MARK: - Release

    /// Returns one fan to System. Clears Ftst when the last owned fan is released.
    public func release(_ index: Int) throws {
        let fan = try descriptor(index)
        guard ownedFans.contains(index) else { return }
        try releaseFan(fan)
        ownedFans.remove(index)
        appliedRPM[index] = nil
        try clearFtstAfterLastRelease()
    }

    private func releaseFan(_ fan: FanDescriptor) throws {
        switch profile.scheme {
        case .appleSilicon, .intelModeKey:
            if let mode = fan.modeKey { try releaseMode(fan, mode) }
            if case .intelModeKey = profile.scheme, allowList.contains(FanHardwareProfile.forceBitsKey) { try clearForceBit(fan.index) }
        case .intelForceBits:
            try clearForceBit(fan.index)
        case .intelMinimumOnly:
            try restoreSavedMinimum(fan.index)
        case .none: break
        }
    }

    private func restoreSavedMinimum(_ index: Int) throws {
        guard let original = savedMinimumBytes[index] else { return }
        try write(.fan("F%dMn", index), original)
        savedMinimumBytes[index] = nil
    }

    private func clearFtstAfterLastRelease() throws {
        guard ownedFans.isEmpty && ftstSetByUs else { return }
        try writeUInt8(FanHardwareProfile.ftstKey, 0)
        ftstSetByUs = false
        log("Ftst=0 written; macOS reclaims fans")
    }

    private struct ReleasePolicy {
        let operation: String
        let releasesMode: (FanDescriptor, FourCC) -> Bool
        let forceBitsAfter: (UInt16, UInt16) -> UInt16
        let shouldReleaseFtst: (FourCC) -> Bool
    }

    /// Never throws; retries each write of state Thermik recorded. Returns human-readable failures.
    @discardableResult
    public func releaseAll(reason: String) -> [String] {
        let policy = ReleasePolicy(operation: "releaseAll",
                                   releasesMode: { fan, _ in self.ownedFans.contains(fan.index) },
                                   forceBitsAfter: { current, ours in current & ~ours },
                                   shouldReleaseFtst: { _ in self.ftstSetByUs })
        return performRelease(reason: reason, policy: policy)
    }

    /// Also clears unrecorded state left by a crash or an explicit reset. Never throws; retries each write.
    @discardableResult
    public func forceReleaseAll(reason: String) -> [String] {
        let policy = ReleasePolicy(operation: "forceReleaseAll",
                                   releasesMode: { fan, mode in self.ownedFans.contains(fan.index) || self.readUInt8(mode) == 1 },
                                   forceBitsAfter: { _, _ in 0 },
                                   shouldReleaseFtst: { key in self.ftstSetByUs || self.readUInt8(key) == 1 })
        return performRelease(reason: reason, policy: policy)
    }

    private func performRelease(reason: String, policy: ReleasePolicy) -> [String] {
        log("\(policy.operation)(reason: \(reason))")
        var failures: [String] = []
        spinUpFansForRelease(policy)
        releaseFans(policy, failures: &failures)
        releaseForceBits(policy, failures: &failures)
        releaseFtst(policy, failures: &failures)
        if failures.isEmpty { resetAfterRelease() }
        return failures
    }

    private func spinUpFansForRelease(_ policy: ReleasePolicy) {
        for fan in profile.fans {
            guard let mode = fan.modeKey, policy.releasesMode(fan, mode) else { continue }
            try? spinUpForRelease(fan)
        }
    }

    private func releaseFans(_ policy: ReleasePolicy, failures: inout [String]) {
        for fan in profile.fans { release(fan, policy: policy, failures: &failures) }
    }

    private func release(_ fan: FanDescriptor, policy: ReleasePolicy, failures: inout [String]) {
        switch profile.scheme {
        case .appleSilicon, .intelModeKey: releaseModeIfNeeded(fan, policy: policy, failures: &failures)
        case .intelMinimumOnly: restoreMinimum(fan, failures: &failures)
        default: break
        }
    }

    private func releaseModeIfNeeded(_ fan: FanDescriptor, policy: ReleasePolicy, failures: inout [String]) {
        guard let mode = fan.modeKey, policy.releasesMode(fan, mode) else { return }
        attempt("\(mode)=0", { try releaseMode(fan, mode) }, failures: &failures)
    }

    /// Keep the original minimum until it is back in the SMC for retries and the recovery marker.
    private func restoreMinimum(_ fan: FanDescriptor, failures: inout [String]) {
        guard let original = savedMinimumBytes[fan.index] else { return }
        let restored = attempt("F\(fan.index)Mn restore", { try write(.fan("F%dMn", fan.index), original) }, failures: &failures)
        if restored { savedMinimumBytes[fan.index] = nil }
    }

    private func releaseForceBits(_ policy: ReleasePolicy, failures: inout [String]) {
        let key = FanHardwareProfile.forceBitsKey
        guard allowList.contains(key) else { return }
        attempt("FS!=0", { try updateForceBits(key, policy: policy) }, failures: &failures)
    }

    private func updateForceBits(_ key: FourCC, policy: ReleasePolicy) throws {
        let raw = try smc.readRaw(key).1
        let current = raw.count >= 2 ? (UInt16(raw[0]) << 8 | UInt16(raw[1])) : 0
        let ours = ownedFans.reduce(UInt16(0)) { $0 | (UInt16(1) << UInt16($1)) }
        let new = policy.forceBitsAfter(current, ours)
        if new != current { try write(key, [UInt8(new >> 8), UInt8(new & 0xFF)]) }
    }

    private func releaseFtst(_ policy: ReleasePolicy, failures: inout [String]) {
        let key = FanHardwareProfile.ftstKey
        guard allowList.contains(key), policy.shouldReleaseFtst(key) else { return }
        attempt("Ftst=0", { try writeUInt8(key, 0) }, failures: &failures)
    }

    private func resetAfterRelease() {
        ownedFans.removeAll()
        appliedRPM.removeAll()
        ftstSetByUs = false
        lastManualAssert.removeAll()
        spinUpStartedAt.removeAll()
    }

    @discardableResult
    private func attempt(_ what: String, _ body: () throws -> Void, failures: inout [String]) -> Bool {
        for n in 1...max(1, timing.restoreAttempts) {
            do { try body(); return true } catch {
                if n == max(1, timing.restoreAttempts) { failures.append("\(what): \(error)") } else { clock.sleep(timing.restoreRetryDelay) }
            }
        }
        return false
    }

    /// Mode back to System. A fan Thermik stopped (target 0) cannot go straight back on M4 Max: the SMC refuses
    /// `F%dMd=0` with 0x82 while it stands still (macOS 27, 2026-10-27), which left both fans manual at 0 rpm with
    /// nobody driving them. Such a fan first gets its minimum as the target, and the mode write is retried until
    /// `releaseSpinUpDeadline` after that. Past the deadline one write per call is left, for the helper's later
    /// forced retries.
    private func releaseMode(_ fan: FanDescriptor, _ modeKey: FourCC) throws {
        try spinUpForRelease(fan)
        guard let started = spinUpStartedAt[fan.index] else { try writeUInt8(modeKey, 0); return }
        while true {
            do {
                try finishReleaseMode(fan, modeKey: modeKey, started: started)
                return
            } catch {
                try waitForReleaseRetry(started: started, error: error)
            }
        }
    }

    private func finishReleaseMode(_ fan: FanDescriptor, modeKey: FourCC, started: Date) throws {
        try writeUInt8(modeKey, 0)
        spinUpStartedAt[fan.index] = nil
        log(String(format: "fan %d: stopped fan spun up to %.0f rpm and handed back %.2fs after the spin-up", fan.index,
                   fan.minRPM, clock.now().timeIntervalSince(started)))
    }

    private func waitForReleaseRetry(started: Date, error: Error) throws {
        guard clock.now().timeIntervalSince(started) < timing.releaseSpinUpDeadline else { throw error }
        clock.sleep(timing.releaseSpinUpRetryInterval)
    }

    /// A stopped fan gets its minimum as the target (once: afterwards it no longer counts as stopped).
    private func spinUpForRelease(_ fan: FanDescriptor) throws {
        guard profile.scheme.allowsFanStop, isStopped(fan) else { return }
        let tg = FourCC.fan("F%dTg", fan.index)
        let info: SMCKeyInfo
        do { info = try smc.keyInfo(tg) } catch let e as SMCError { throw FanWriteError.smc(e) }
        let bytes: [UInt8]
        do { bytes = try SMCCodec.encodeRPM(fan.minRPM, as: info, key: tg) } catch let e as SMCError { throw FanWriteError.smc(e) }
        try write(tg, bytes)
        appliedRPM[fan.index] = fan.minRPM
        spinUpStartedAt[fan.index] = clock.now()
        log(String(format: "fan %d: stopped; target %.0f rpm so it can be handed back", fan.index, fan.minRPM))
    }

    /// The target Thermik last wrote, or the SMC's own for a fan a previous helper instance left behind.
    private func isStopped(_ fan: FanDescriptor) -> Bool {
        if let applied = appliedRPM[fan.index] { return applied < 1 }
        return ((try? smc.readNumber(.fan("F%dTg", fan.index))) ?? fan.minRPM) < 1
    }

    private func clearFtstBestEffort() {
        if (try? writeUInt8(FanHardwareProfile.ftstKey, 0)) != nil { ftstSetByUs = false }
    }

    /// Fans we believe we own whose live mode is no longer manual (OS reclaimed them).
    public func reclaimedFans() -> [Int] {
        guard case .appleSilicon = profile.scheme else { return [] }
        return ownedFans.filter { i in profile.fan(i)?.modeKey.flatMap { readUInt8($0) } != 1 }.sorted()
    }
}
