// SMCFanController.swift — Thermik (MIT). HELPER ONLY.
// UNIT 0 STUB — Unit 3 replaces the body with the real implementation that composes
// FanWriteSequencer (FANS §5.5), FanReader and ThermalSafetyMonitor (FANS §8.4). Public API is frozen.
import Foundation
import ThermikSMC
import ThermikHelperShared

public final class SMCFanController: FanControlling {
    public let profile: FanHardwareProfile
    private let smc: SMCConnection

    public init(smc: SMCConnection) {
        self.smc = smc
        self.profile = FanHardwareProfile.discover(smc)
    }

    public var isControlling: Bool { false }
    public var ownedFans: Set<Int> { [] }
    public var ftstSetByUs: Bool { false }
    public var appliedRPM: [Int: Double] { [:] }
    public func fanStates() -> [HelperFanState] { [] }
    public func ftstValue() -> Int? { nil }
    public func setManual(_ index: Int, targetRPM: Double) throws -> Double { throw FanWriteError.notControllable }
    public func setAutomatic(_ index: Int) throws {}
    @discardableResult public func restoreAll(force: Bool, reason: String) -> [String] { [] }
    public func adoptPersistedState(ftstSetByUs: Bool) {}
    public func reclaimedFans() -> [Int] { [] }
    public func foreignControlSuspected() -> Bool { false }
    public func evaluateSafety() -> SafetyVerdict { .normal(hottestC: nil) }
}
