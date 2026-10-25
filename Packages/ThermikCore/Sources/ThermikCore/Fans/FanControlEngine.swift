// FanControlEngine.swift — Thermik (MIT). OWNER: Unit 3. STUB from Unit 0; API FROZEN.
// Pure logic (no I/O): (plan, temperatures, time) → per-fan commands. Runs on the main actor at 1 Hz.
// Unit 3 ports research/fans/code/AppOnly/FanControlEngine.swift (SensorSource → TemperatureSource) + thermal guard.
import Foundation
import ThermikSMC

public final class FanControlEngine {
    public let profile: FanHardwareProfile
    public var writeDeadbandRPM: Double = 50
    public var settleSeconds: Double = 5
    public var nominalTick: Double = 1
    public private(set) var safetyLatched = false
    public private(set) var thermalGuardActive = false

    public init(profile: FanHardwareProfile) { self.profile = profile }

    /// Call after the helper reverted (sleep, lease expiry) so slewing restarts from the live speed.
    public func resetState() { safetyLatched = false; thermalGuardActive = false }

    /// - temperatures: resolved values for `plan.referencedSources` (smoothed).
    /// - safetyTempC: AggregateKind.safetyTop4 (smoothed); rawHottestC: AggregateKind.rawHottestDie (raw).
    public func tick(now: Date, temperatures: [TemperatureSource: Double], safetyTempC: Double?, rawHottestC: Double?,
                     pressure: ThermalPressure, plan: FanPlan) -> [Int: FanCommand] {
        Dictionary(uniqueKeysWithValues: profile.fans.map { ($0.index, FanCommand.system) })
    }

    /// Sorted by °C, percent clamped 0…100 and made non-decreasing (used by the curve editor too).
    public static func normalized(_ pts: [CurvePoint]) -> [CurvePoint] { pts.sorted { $0.celsius < $1.celsius } }
    public static func interpolate(_ pts: [CurvePoint], _ t: Double) -> Double { 0 }
}

/// Builds the engine plan from the user's config for the current power source.
public enum FanPlanBuilder {
    public static func plan(config: FanUserConfig, power: PowerSourceKind, profile: FanHardwareProfile) -> FanPlan { FanPlan() }
}
