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
/// HelperService keeps them in the recovery marker. An optional companion of the frozen `FanControlling` contract
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
            let key = FourCC.fan("F%dMn", index)
            guard let fan = profile.fan(index), let info = try? smc.keyInfo(key),
                  original.count == Int(info.size), let rpm = SMCCodec.decode(original, as: info).doubleValue,
                  rpm.isFinite, rpm >= 0, rpm < fan.maxRPM else {
                log("fan \(index): ignoring the recovered F\(index)Mn bytes \(original)")
                continue
            }
            if let current = try? smc.readRaw(key).1, current == original { continue }
            savedMinimumBytes[index] = original
            log(String(format: "fan %d: original F%dMn %.0f rpm recovered from the marker", index, index, rpm))
        }
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
        case .appleSilicon(_, let hasFtst):
            guard let modeKey = fan.modeKey else { throw FanWriteError.notControllable }
            if ownedFans.contains(index), readUInt8(modeKey) == 1 { return }
            if ownedFans.contains(index) {
                // We owned it but macOS took it back (wake, thermal reclaim). Throttle re-asserts.
                if let last = lastManualAssert[index], clock.now().timeIntervalSince(last) < timing.minReassertInterval {
                    throw FanWriteError.reclaimedTooSoon(fan: index)
                }
                ownedFans.remove(index)
            }
            lastManualAssert[index] = clock.now()
            try enterManualAppleSilicon(index: index, modeKey: modeKey, hasFtst: hasFtst, onManual: onManual)
        case .intelModeKey:
            guard let modeKey = fan.modeKey else { throw FanWriteError.notControllable }
            if readUInt8(modeKey) != 1 { try writeUInt8(modeKey, 1) }
            if allowList.contains(FanHardwareProfile.forceBitsKey) { try setForceBit(index, on: true) }
        case .intelForceBits:
            try setForceBit(index, on: true)
        case .intelMinimumOnly:
            if savedMinimumBytes[index] == nil {
                do { savedMinimumBytes[index] = try smc.readRaw(.fan("F%dMn", index)).1 } catch let e as SMCError { throw FanWriteError.smc(e) }
                // I7: the original reaches the recovery marker before anything raises it.
                do { try willRaiseMinimum?(index) } catch { savedMinimumBytes[index] = nil; throw error }
            }
        }
        ownedFans.insert(index)
    }

    private func enterManualAppleSilicon(index: Int, modeKey: FourCC, hasFtst: Bool, onManual: (() throws -> Void)?) throws {
        let ftst = FanHardwareProfile.ftstKey
        // Phase 1: direct write (M1/M2/M5, and M3/M4 when the OS is not asserting mode 3).
        var lastError = "none"
        do {
            try writeUInt8(modeKey, 1)
            clock.sleep(timing.readBackDelay)
            if readUInt8(modeKey) == 1 {
                // No Ftst on this Mac, or Ftst already 1 (unlock in effect): nothing to escalate to / no reclaim risk.
                if !hasFtst || readUInt8(ftst) == 1 { log("fan \(index): manual via direct write"); return }
                if directWriteSticks && !ownedFans.isEmpty { log("fan \(index): manual via direct write (sticky earlier)"); return }
                try? onManual?()                       // ramp during the check; setTarget writes the target again after it
                clock.sleep(timing.stickCheckDelay)
                if readUInt8(modeKey) == 1 { directWriteSticks = true; log("fan \(index): manual via direct write (sticky)"); return }
                lastError = "direct write reclaimed by macOS"
            } else { lastError = "direct write not reflected in read-back" }
        } catch {
            lastError = "\(error)"     // typically SMC 0x82 (kSMCBadCommand) while macOS holds mode 3
        }
        guard hasFtst else {
            throw FanWriteError.unlockTimeout(fan: index, elapsed: 0, lastError: lastError)
        }

        // Phase 2: Ftst unlock (M3/M4). Ftst is global; set it once.
        let start = clock.now()
        if readUInt8(ftst) != 1 {
            ftstSetByUs = true                         // set first: clearing an already-0 Ftst later is harmless
            try writeUInt8(ftst, 1)
            log("Ftst=1 written; waiting for thermalmonitord to yield")
            clock.sleep(timing.settleAfterFtst)
        }
        while clock.now().timeIntervalSince(start) < timing.unlockDeadline {
            do {
                try writeUInt8(modeKey, 1)
                clock.sleep(timing.readBackDelay)
                if readUInt8(modeKey) == 1 {
                    log(String(format: "fan %d: manual via Ftst unlock after %.2fs", index, clock.now().timeIntervalSince(start)))
                    return
                }
                lastError = "mode write accepted but not reflected"
            } catch {
                lastError = "\(error)"
            }
            clock.sleep(timing.retryInterval)
        }
        // Failed: do not leave Ftst=1 behind if nothing else needs it.
        if ownedFans.isEmpty && ftstSetByUs { clearFtstBestEffort() }
        throw FanWriteError.unlockTimeout(fan: index, elapsed: clock.now().timeIntervalSince(start), lastError: lastError)
    }

    private func setForceBit(_ index: Int, on: Bool) throws {
        let key = FanHardwareProfile.forceBitsKey
        let raw: [UInt8]
        do { raw = try smc.readRaw(key).1 } catch let e as SMCError { throw FanWriteError.smc(e) }
        guard raw.count >= 2 else { throw FanWriteError.smc(.sizeMismatch(key: key, expected: 2, actual: raw.count)) }
        let cur = UInt16(raw[0]) << 8 | UInt16(raw[1])                 // big-endian bitmask
        let bit = UInt16(1) << UInt16(index)
        let new = on ? (cur | bit) : (cur & ~bit)
        if new != cur { try write(key, [UInt8(new >> 8), UInt8(new & 0xFF)]) }
    }

    // MARK: - Target

    /// Clamps, encodes per key type, writes, and returns the RPM actually written.
    @discardableResult
    public func setTarget(_ index: Int, rpm requested: Double) throws -> Double {
        let fan = try descriptor(index)
        guard requested.isFinite, requested >= 0 else { throw FanWriteError.smc(.invalidValue("rpm \(requested)")) }
        // I1: the SMC does no sanity checks. Exactly 0 is a stop where the hardware has one (the helper decides when).
        let rpm = requested == 0 && profile.scheme.allowsFanStop ? 0 : fan.clamp(requested).rounded()
        // Early target write for the stick check (Apple Silicon direct path); encoding problems surface below.
        let earlyTarget: (() throws -> Void)? = profile.scheme == .intelMinimumOnly ? nil : { [self] in
            let key = FourCC.fan("F%dTg", index)
            try self.write(key, try SMCCodec.encodeRPM(rpm, as: try smc.keyInfo(key), key: key))
        }
        try ensureManual(index, onManual: earlyTarget)

        if profile.scheme == .intelMinimumOnly {
            let key = FourCC.fan("F%dMn", index)
            let info: SMCKeyInfo
            do { info = try smc.keyInfo(key) } catch let e as SMCError { throw FanWriteError.smc(e) }
            let bytes: [UInt8]
            do { bytes = try SMCCodec.encodeRPM(rpm, as: info, key: key) } catch let e as SMCError { throw FanWriteError.smc(e) }
            try write(key, bytes)
            appliedRPM[index] = rpm
            return rpm
        }

        let key = FourCC.fan("F%dTg", index)
        let info: SMCKeyInfo
        do { info = try smc.keyInfo(key) } catch let e as SMCError { throw FanWriteError.smc(e) }
        let bytes: [UInt8]
        do { bytes = try SMCCodec.encodeRPM(rpm, as: info, key: key) } catch let e as SMCError { throw FanWriteError.smc(e) }
        do {
            try write(key, bytes)
        } catch FanWriteError.smc(.firmware(SMCResultCode.keySizeMismatch.rawValue, _)) {
            // kSMCKeySizeMismatch (0x87): observed on F0Tg with the value applied anyway (agoodkind). Verify.
            clock.sleep(timing.readBackDelay)
            let back = (try? smc.readNumber(key)) ?? -1
            guard abs(back - rpm) < 1 else {
                throw FanWriteError.verificationFailed(key: key, expected: "\(rpm)", actual: "\(back)")
            }
        }
        appliedRPM[index] = rpm
        spinUpStartedAt[index] = nil
        return rpm
    }

    // MARK: - Release

    /// Returns one fan to System. Clears Ftst when the last owned fan is released.
    public func release(_ index: Int) throws {
        let fan = try descriptor(index)
        guard ownedFans.contains(index) else { return }
        switch profile.scheme {
        case .appleSilicon, .intelModeKey:
            if let m = fan.modeKey { try releaseMode(fan, m) }
            if case .intelModeKey = profile.scheme, allowList.contains(FanHardwareProfile.forceBitsKey) { try setForceBit(index, on: false) }
        case .intelForceBits:
            try setForceBit(index, on: false)
        case .intelMinimumOnly:
            if let orig = savedMinimumBytes[index] { try write(.fan("F%dMn", index), orig); savedMinimumBytes[index] = nil }
        case .none: break
        }
        ownedFans.remove(index)
        appliedRPM[index] = nil
        if ownedFans.isEmpty && ftstSetByUs {
            try writeUInt8(FanHardwareProfile.ftstKey, 0); ftstSetByUs = false; log("Ftst=0 written; macOS reclaims fans")
        }
    }

    /// Never throws; retries each write. `force == true` also clears state Thermik did
    /// not record (startup recovery after SIGKILL, or explicit user "Reset to System").
    /// Returns human-readable failures (empty == fully restored).
    @discardableResult
    public func releaseAll(force: Bool, reason: String) -> [String] {
        log("releaseAll(force: \(force), reason: \(reason))")
        var failures: [String] = []
        @discardableResult func attempt(_ what: String, _ body: () throws -> Void) -> Bool {
            for n in 1...max(1, timing.restoreAttempts) {
                do { try body(); return true } catch {
                    if n == max(1, timing.restoreAttempts) { failures.append("\(what): \(error)") } else { clock.sleep(timing.restoreRetryDelay) }
                }
            }
            return false
        }
        func releasesMode(_ fan: FanDescriptor) -> Bool {
            fan.modeKey.map { ownedFans.contains(fan.index) || (force && readUInt8($0) == 1) } ?? false
        }
        // Every stopped fan spins up first, so their waits in `releaseMode` overlap.
        for fan in profile.fans where releasesMode(fan) { try? spinUpForRelease(fan) }
        for fan in profile.fans {
            switch profile.scheme {
            case .appleSilicon, .intelModeKey:
                if let m = fan.modeKey, releasesMode(fan) {
                    attempt("\(m)=0") { try releaseMode(fan, m) }
                }
            case .intelMinimumOnly:
                // Keep the original until it is back in the SMC: the scheduled retry needs it, and so does the
                // recovery marker that HelperService keeps while the restore is incomplete.
                if let orig = savedMinimumBytes[fan.index],
                   attempt("F\(fan.index)Mn restore", { try write(.fan("F%dMn", fan.index), orig) }) {
                    savedMinimumBytes[fan.index] = nil
                }
            default: break
            }
        }
        let fsKey = FanHardwareProfile.forceBitsKey
        if allowList.contains(fsKey) {
            attempt("FS!=0") {
                let raw = try smc.readRaw(fsKey).1
                let cur = raw.count >= 2 ? (UInt16(raw[0]) << 8 | UInt16(raw[1])) : 0
                let ours = ownedFans.reduce(UInt16(0)) { $0 | (UInt16(1) << UInt16($1)) }
                let new = force ? 0 : (cur & ~ours)
                if new != cur { try write(fsKey, [UInt8(new >> 8), UInt8(new & 0xFF)]) }
            }
        }
        let ftst = FanHardwareProfile.ftstKey
        if allowList.contains(ftst), ftstSetByUs || (force && readUInt8(ftst) == 1) {
            attempt("Ftst=0") { try writeUInt8(ftst, 0) }
        }
        if failures.isEmpty {
            ownedFans.removeAll(); appliedRPM.removeAll(); ftstSetByUs = false; lastManualAssert.removeAll(); spinUpStartedAt.removeAll()
        }
        return failures
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
                try writeUInt8(modeKey, 0)
                spinUpStartedAt[fan.index] = nil
                log(String(format: "fan %d: stopped fan spun up to %.0f rpm and handed back %.2fs after the spin-up", fan.index,
                           fan.minRPM, clock.now().timeIntervalSince(started)))
                return
            } catch {
                guard clock.now().timeIntervalSince(started) < timing.releaseSpinUpDeadline else { throw error }
                clock.sleep(timing.releaseSpinUpRetryInterval)
            }
        }
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
