// SensorSampler.swift — Thermik (MIT). OWNER: Unit 1. Unit 0 ships this compiling STUB; Unit 1 replaces the body.
// Public API is FROZEN: `public actor SensorSampler: SensorSampling` + `init()`.
import Foundation
import ThermikSMC

public actor SensorSampler: SensorSampling {
    public init() {}

    public func start() async throws -> SensorInventory {
        let identity = ChipIdentity(platformName: "unknown", targetType: nil, modelIdentifier: "Mac", chipName: "Unknown",
                                    isAppleSilicon: HostInfo.isAppleSilicon, smcPlatform: nil)
        return SensorInventory(identity: identity, sensors: [], headline: [:], safetySet: [], fanProfile: .none,
                               catalogStatus: .heuristic(platform: "unknown"), smcAvailable: false, smcKeyCount: 0,
                               dieLayout: [], fanNames: nil)
    }
    public func sample(_ request: SampleRequest) async -> SensorFrame { .empty() }
    public func willSleep() async {}
    public func didWake() async {}
}
