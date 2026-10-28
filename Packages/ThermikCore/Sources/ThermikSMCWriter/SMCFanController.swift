// SMCFanController.swift — Thermik (MIT). HELPER ONLY. The real `FanControlling` behind HelperService (Unit 4):
// FanWriteSequencer (writes, allow-list, Ftst unlock, clamp) + FanReader (live state) + ThermalSafetyMonitor
// (I8/I9). Called only on the helper's serial state queue, so it keeps no locks of its own.
//
// Safety invariants implemented here (SPEC §2.6.2): I1 clamp and I2 allow-list (sequencer), I8/I9 verdicts
// (monitor; HelperService acts on them), I10 `foreignControlSuspected()`. Lease, client-gone, signals, sleep and
// the recovery marker (I3–I7) belong to HelperService.
//
// SMC link: the helper keeps one `SMCConnection` for its lifetime. It replaces a stale user client by itself and,
// while AppleSMC cannot be opened, retries with backoff. This class logs the link's transitions, answers I9 with
// `.sensorFailure` while it is down and until a restore the outage interrupted has completed (HelperService then
// keeps retrying the restore, so control is never silently resumed half-reverted), and keeps the safety monitor's
// one-time key discovery off a dead link.
import Foundation
import os
import ThermikSMC
import ThermikHelperShared

public final class SMCFanController: FanControlling {
    public let profile: FanHardwareProfile
    private let smc: any SMCReadWriting
    /// The production connection, for its link state (nil for `FakeSMC` in `thermik-probe fans sim`).
    private let link: SMCConnection?
    private let sequencer: FanWriteSequencer
    private var safety: ThermalSafetyMonitor
    private let appleSilicon: Bool
    private let log: (String) -> Void
    /// The crash-recovery marker (I7). While it exists the fans may still be Thermik's (a previous helper instance
    /// died while controlling), so forcing seen in the SMC is not evidence of a foreign controller (I10).
    /// nil disables the check. HelperService (Unit 4) owns the file; this class only tests for its presence.
    public var markerPath: String? = ThermikHelper.manualMarkerPath
    /// Set by `adoptPersistedState` (the marker was found at startup) until the next full restore.
    private var recoveringFromMarker = false
    /// The monitor's die keys were discovered over a working link (`safetyKeysReady()`).
    private var safetyKeysTrusted = false
    /// The last restore failed because the link was down: it is finished before control goes on (`evaluateSafety`),
    /// unless a new command gets through first.
    private var restoreInterrupted = false
    /// Link state as last logged (`noteLink()`).
    private var linkReportedDown = false
    private var linkReopens = 0

    private static let linkLog = Logger(subsystem: ThermikHelper.label, category: "smc")

    /// The production entry point: the helper's own read/write connection.
    public convenience init(smc: SMCConnection) {
        self.init(device: smc)
    }

    /// Package-internal designated initializer: the offline simulator (`thermik-probe fans sim`) drives the full
    /// controller against `FakeSMC` with a simulated clock. Not visible to the app or the helper target.
    package init(device: any SMCReadWriting, appleSilicon: Bool = HostInfo.isAppleSilicon,
                 clock: any SequencerClock = SystemSequencerClock(), timing: FanWriteTiming = FanWriteTiming(),
                 log: @escaping (String) -> Void = FanWriteSequencer.defaultLog) {
        smc = device
        link = device as? SMCConnection
        self.appleSilicon = appleSilicon
        self.log = log
        profile = FanHardwareProfile.discover(device, appleSilicon: appleSilicon)
        sequencer = FanWriteSequencer(smc: device, profile: profile, clock: clock, timing: timing, log: log)
        safety = ThermalSafetyMonitor(smc: device, appleSilicon: appleSilicon, clock: clock)
    }

    public var isControlling: Bool { sequencer.isControlling }
    public var ownedFans: Set<Int> { sequencer.ownedFans }
    public var ftstSetByUs: Bool { sequencer.ftstSetByUs }
    public var appliedRPM: [Int: Double] { sequencer.appliedRPM }
    /// Thermal override currently latched by the monitor (HelperState.safetyOverrideActive).
    public var safetyOverrideActive: Bool { safety.overrideActive }
    /// Die keys the safety monitor reads (diagnostics). Empty while the SMC link is down.
    public var monitoredSafetyKeys: [FourCC] { safetyKeysReady() ? safety.monitoredKeys : [] }

    public func fanStates() -> [HelperFanState] {
        defer { noteLink() }
        let snap = FanReader.snapshot(smc, profile: profile)
        return snap.fans.compactMap { s in
            guard let f = profile.fan(s.index) else { return nil }
            return HelperFanState(index: s.index, minRPM: f.minRPM, maxRPM: f.maxRPM, actualRPM: s.actualRPM,
                                  targetRPM: s.targetRPM, modeRaw: s.mode.map { Int($0.raw) },
                                  ownedByThermik: sequencer.ownedFans.contains(s.index),
                                  appliedRPM: sequencer.appliedRPM[s.index])
        }
    }

    public func ftstValue() -> Int? {
        guard profile.hasFtstKey else { return nil }
        return (try? smc.readUInt8(FanHardwareProfile.ftstKey)).map(Int.init)
    }

    public func setManual(_ index: Int, targetRPM: Double) throws -> Double {
        guard profile.isControllable else { throw FanWriteError.notControllable }
        defer { noteLink() }
        let hadFtst = sequencer.ftstSetByUs
        do {
            let applied = try sequencer.setTarget(index, rpm: targetRPM)
            restoreInterrupted = false            // a command that got through supersedes the interrupted restore
            return applied
        } catch {
            dropUnappliedFtst(hadFtst: hadFtst)
            throw error
        }
    }

    public func setAutomatic(_ index: Int) throws {
        guard profile.fan(index) != nil else { throw FanWriteError.invalidFan(index) }
        defer { noteLink() }
        try sequencer.release(index)
        if !sequencer.isControlling { safety.reset() }
    }

    @discardableResult public func restoreAll(force: Bool, reason: String) -> [String] {
        defer { noteLink() }
        let linkFailures = link?.connectionFailureCount
        let failures = sequencer.releaseAll(force: force, reason: reason)
        if failures.isEmpty {
            recoveringFromMarker = false
            safety.reset()
        }
        restoreInterrupted = !failures.isEmpty && link?.connectionFailureCount != linkFailures
        return failures
    }

    public func adoptPersistedState(ftstSetByUs: Bool) {
        sequencer.adoptPersistedState(ftstSetByUs: ftstSetByUs)
        recoveringFromMarker = true
    }

    public func reclaimedFans() -> [Int] { sequencer.reclaimedFans() }

    /// I10: `!isControlling && marker == nil && FanReader.snapshot(...).anyManual` (SPEC §2.6.3).
    public func foreignControlSuspected() -> Bool {
        guard !isControlling, !recoveringFromMarker else { return false }
        if let path = markerPath, FileManager.default.fileExists(atPath: path) { return false }
        return FanReader.snapshot(smc, profile: profile).anyManual
    }

    /// I8/I9. Reads the die set only while Thermik holds the fans; macOS is in charge otherwise. With the SMC link
    /// down no die sensor can be read: `.sensorFailure` (I9) at once, also when the link died during this reading,
    /// and after it is back until the restore it interrupted has gone through.
    public func evaluateSafety() -> SafetyVerdict {
        guard isControlling else { return .normal(hottestC: nil) }
        guard let link else { return safety.evaluate() }
        defer { noteLink() }
        guard !restoreInterrupted, safetyKeysReady() else { return .sensorFailure }
        let failures = link.connectionFailureCount
        let verdict = safety.evaluate()
        return link.connectionFailureCount == failures ? verdict : .sensorFailure
    }

    public func currentHottestDieC() -> Double? {
        if link != nil {
            defer { noteLink() }
            guard !restoreInterrupted, safetyKeysReady() else { return nil }
        }
        return safety.readHottest()
    }

    // MARK: SMC link

    /// Runs the monitor's lazy, one-time die-key discovery on a link known to work. Over a dead link it would cache an
    /// empty (or partial) key set for the helper's lifetime and silence I8/I9, so such a discovery is thrown away and
    /// repeated on a later call. False while the link is down.
    private func safetyKeysReady() -> Bool {
        guard !safetyKeysTrusted else { return true }
        guard let link else { safetyKeysTrusted = true; return true }
        if !link.isOpen { _ = try? link.keyCount() }                 // reopens once the backoff has passed
        guard link.isOpen else { return false }
        let failures = link.connectionFailureCount
        _ = safety.monitoredKeys
        guard link.connectionFailureCount == failures else {
            safety = ThermalSafetyMonitor(smc: smc, appleSilicon: appleSilicon, clock: sequencer.clock)
            return false
        }
        safetyKeysTrusted = true
        return true
    }

    /// The sequencer marks Ftst as Thermik's *before* writing it, so an Ftst=1 that took effect but reported an error
    /// is still cleared later. When the unlock then failed with no fan held and Ftst reads 0 after the write latency,
    /// nothing of Thermik's is in effect (the firmware refused the write): the mark is dropped. Otherwise
    /// `isControlling` would stay true for nothing, blocking idle exit (I13) behind a restore that may never succeed.
    /// An unreadable Ftst (link down) keeps the mark: the restore clears it once a write gets through.
    private func dropUnappliedFtst(hadFtst: Bool) {
        guard !hadFtst, sequencer.ftstSetByUs, sequencer.ownedFans.isEmpty else { return }
        sequencer.clock.sleep(sequencer.timing.readBackDelay)
        guard ftstValue() == 0 else { return }
        sequencer.adoptPersistedState(ftstSetByUs: false)
        log("Ftst=1 was not accepted (reads 0): nothing to restore")
    }

    /// Logs each link transition once. The connection reopens by itself (with backoff); meanwhile writes and restores
    /// fail as "not open" and HelperService keeps retrying the restore.
    private func noteLink() {
        guard let link else { return }
        let reopens = link.reopenCount
        let down = !link.isOpen
        defer { linkReopens = reopens; linkReportedDown = down }
        if down, !linkReportedDown {
            Self.linkLog.error("SMC connection lost and cannot be reopened yet: fan writes and restores fail until it is back (retried with backoff)")
        } else if !down, linkReportedDown {
            Self.linkLog.notice("SMC connection restored")
        } else if !down, reopens != linkReopens {
            Self.linkLog.notice("SMC connection was stale: reopened")
        }
    }
}

/// intelMinimumOnly crash recovery (I7): forwarded to the sequencer, which owns the original F%dMn bytes.
extension SMCFanController: MinimumOnlyRecovery {
    public var savedMinimumBytes: [Int: [UInt8]] { sequencer.savedMinimumBytes }
    public var willRaiseMinimum: ((Int) throws -> Void)? {
        get { sequencer.willRaiseMinimum }
        set { sequencer.willRaiseMinimum = newValue }
    }
    public func adoptSavedMinimumBytes(_ bytes: [Int: [UInt8]]) { sequencer.adoptSavedMinimumBytes(bytes) }
}
