// MockFanController.swift — Thermik (MIT). In-memory FanControlling for `thermik-helper --mock`,
// `thermik-probe helper-selftest` and demo mode. Never touches the SMC.
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
            HelperFanState(index: f.index, minRPM: f.minRPM, maxRPM: f.maxRPM, actualRPM: actual[f.index] ?? 0,
                           targetRPM: appliedRPM[f.index] ?? f.minRPM, modeRaw: ownedFans.contains(f.index) ? 1 : 0,
                           ownedByThermik: ownedFans.contains(f.index), appliedRPM: appliedRPM[f.index])
        }
    }

    public func ftstValue() -> Int? { ftstSetByUs ? 1 : 0 }

    public func setManual(_ index: Int, targetRPM: Double) throws -> Double {
        guard let f = profile.fan(index) else { throw FanWriteError.invalidFan(index) }
        guard targetRPM.isFinite, targetRPM >= 0 else { throw FanWriteError.smc(.invalidValue("rpm \(targetRPM)")) }
        let rpm = f.clamp(targetRPM).rounded()
        ftstSetByUs = true
        ownedFans.insert(index)
        appliedRPM[index] = rpm
        actual[index] = rpm
        log.append("manual \(index) \(Int(rpm))")
        return rpm
    }

    public func setAutomatic(_ index: Int) throws {
        guard profile.fan(index) != nil else { throw FanWriteError.invalidFan(index) }
        ownedFans.remove(index)
        appliedRPM[index] = nil
        if ownedFans.isEmpty { ftstSetByUs = false }
        log.append("auto \(index)")
    }

    @discardableResult public func restoreAll(force: Bool, reason: String) -> [String] {
        ownedFans.removeAll(); appliedRPM.removeAll(); ftstSetByUs = false
        log.append("restoreAll(force: \(force), reason: \(reason))")
        return []
    }

    public func adoptPersistedState(ftstSetByUs: Bool) { self.ftstSetByUs = ftstSetByUs }
    public func reclaimedFans() -> [Int] { [] }
    public func foreignControlSuspected() -> Bool { simulatedForeignControl && !isControlling }

    public func evaluateSafety() -> SafetyVerdict {
        guard let t = simulatedHottestC else { return .sensorFailure }
        if t >= ThermikHelper.Safety.overrideHottestC { return .override(hottestC: t, top4MeanC: t) }
        return .normal(hottestC: t)
    }
}
