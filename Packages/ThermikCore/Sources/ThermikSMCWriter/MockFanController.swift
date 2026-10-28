// MockFanController.swift — Thermik (MIT). In-memory FanControlling for `thermik-helper --mock`,
// `thermik-probe helper selftest` and demo mode. Never touches the SMC.
// Mirrors the real controller's observable semantics: clamp to [Mn, Mx] (I1), Ftst "unlock" on the first manual
// fan (optionally blocking for `simulatedUnlockSeconds`, like M3/M4), Ftst cleared with the last owned fan,
// foreign control only while not controlling (I10), override latched at ≥ 108 °C until < 95 °C (I8).
import Foundation
import ThermikSMC
import ThermikHelperShared

public final class MockFanController: FanControlling {
    public let profile: FanHardwareProfile
    public private(set) var ownedFans: Set<Int> = []
    public private(set) var ftstSetByUs = false
    public private(set) var appliedRPM: [Int: Double] = [:]
    public private(set) var log: [String] = []
    public var simulatedHottestC: Double? = 60
    public var simulatedForeignControl = false
    /// Blocking delay of the first manual command (0 = instant). M4 Max reality: 3–6 s.
    public var simulatedUnlockSeconds: Double = 0
    /// Fans that "macOS reclaimed" (returned by `reclaimedFans()` while owned).
    public var simulatedReclaimedFans: Set<Int> = []
    public private(set) var safetyOverrideActive = false
    private var actual: [Int: Double] = [:]

    /// Default: M4 Max 16" layout (2 fans, 1350…5777 rpm, Ftst scheme).
    public init(fanCount: Int = 2, minRPM: Double = 1350, maxRPM: Double = 5777) {
        let fans = (0..<fanCount).map {
            FanDescriptor(index: $0, name: $0 == 0 ? "Left Fan" : "Right Fan", minRPM: minRPM, maxRPM: maxRPM,
                          targetType: .flt, modeKey: .fan(FanHardwareProfile.modeUpper, $0))
        }
        var p = FanHardwareProfile(fans: fans, scheme: .appleSilicon(modeKeyTemplate: FanHardwareProfile.modeUpper, hasFtst: true))
        p.hasFtstKey = true
        profile = p
        for f in fans { actual[f.index] = minRPM }
    }

    public var isControlling: Bool { !ownedFans.isEmpty || ftstSetByUs }

    public func fanStates() -> [HelperFanState] {
        profile.fans.map { f in
            let owned = ownedFans.contains(f.index) && !simulatedReclaimedFans.contains(f.index)
            return HelperFanState(index: f.index, minRPM: f.minRPM, maxRPM: f.maxRPM, actualRPM: actual[f.index] ?? 0,
                                  targetRPM: appliedRPM[f.index] ?? f.minRPM,
                                  modeRaw: owned ? 1 : 0,
                                  ownedByThermik: ownedFans.contains(f.index), appliedRPM: appliedRPM[f.index])
        }
    }

    public func ftstValue() -> Int? { ftstSetByUs || (simulatedForeignControl && !isControlling) ? 1 : 0 }

    public func setManual(_ index: Int, targetRPM: Double) throws -> Double {
        guard let f = profile.fan(index) else { throw FanWriteError.invalidFan(index) }
        guard targetRPM.isFinite, targetRPM >= 0 else { throw FanWriteError.smc(.invalidValue("rpm \(targetRPM)")) }
        let rpm = targetRPM == 0 && profile.scheme.allowsFanStop ? 0 : f.clamp(targetRPM).rounded()
        if !ftstSetByUs {
            if simulatedUnlockSeconds > 0 { Thread.sleep(forTimeInterval: simulatedUnlockSeconds) }
            ftstSetByUs = true
            log.append("Ftst=1")
        }
        ownedFans.insert(index)
        simulatedReclaimedFans.remove(index)
        appliedRPM[index] = rpm
        actual[index] = rpm
        log.append("manual \(index) \(Int(rpm))")
        return rpm
    }

    public func setAutomatic(_ index: Int) throws {
        guard profile.fan(index) != nil else { throw FanWriteError.invalidFan(index) }
        guard ownedFans.contains(index) else { return }
        ownedFans.remove(index)
        appliedRPM[index] = nil
        log.append("auto \(index)")
        if ownedFans.isEmpty && ftstSetByUs { ftstSetByUs = false; log.append("Ftst=0") }
    }

    @discardableResult public func restoreAll(force: Bool, reason: String) -> [String] {
        ownedFans.removeAll(); appliedRPM.removeAll(); ftstSetByUs = false; simulatedReclaimedFans.removeAll()
        safetyOverrideActive = false
        log.append("restoreAll(force: \(force), reason: \(reason))")
        return []
    }

    public func adoptPersistedState(ftstSetByUs: Bool) { self.ftstSetByUs = ftstSetByUs }
    public func reclaimedFans() -> [Int] { ownedFans.intersection(simulatedReclaimedFans).sorted() }
    public func foreignControlSuspected() -> Bool { simulatedForeignControl && !isControlling }

    /// `simulatedHottestC` stands for both the hottest key and the top-4 mean; nil == no readable sensor.
    public func currentHottestDieC() -> Double? { simulatedHottestC }

    public func evaluateSafety() -> SafetyVerdict {
        guard let t = simulatedHottestC else { return .sensorFailure }
        if t >= ThermikHelper.Safety.overrideHottestC { safetyOverrideActive = true }
        else if safetyOverrideActive && t < ThermikHelper.Safety.releaseTop4MeanC { safetyOverrideActive = false }
        return safetyOverrideActive ? .override(hottestC: t, top4MeanC: t) : .normal(hottestC: t)
    }
}
