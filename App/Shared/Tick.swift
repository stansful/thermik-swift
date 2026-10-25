// Tick.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). One sampling tick fanned out to all consumers.
import Foundation
import ThermikCore

struct Tick: Sendable {
    let sequence: UInt64
    let date: Date
    /// Seconds since the previous tick (nominal interval on the first tick / after wake).
    let dt: TimeInterval
    let sensors: SensorFrame
    /// nil when the system sampler did not run this tick (its cadence is slower).
    let system: SystemFrame?
    let isFirstAfterWake: Bool
}

/// Registered with SamplingCoordinator in a FIXED order (SPEC §2.3.3). Called on the main actor once per tick.
/// Must be cheap (< 1 ms), must not await, must not throw. Later consumers may read earlier stores.
@MainActor protocol TickConsumer: AnyObject {
    func consume(_ tick: Tick)
}
