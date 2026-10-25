// HelperService.swift — Thermik (MIT). HELPER ONLY. UNIT 0 STUB; OWNER: Unit 4.
// Unit 4 replaces this with the merged service (SPEC §2.6.2 invariants I1–I14): port
// research/helper/skeleton/Helper/{HelperService,PeerValidator,XPCServer,PowerObserver}.swift into this module,
// using `FanControlling` (ThermikSMCWriter) instead of the skeleton's protocol. Public entry points FROZEN:
import Foundation
import ThermikSMC
import ThermikSMCWriter
import ThermikHelperShared

public final class HelperService: @unchecked Sendable {   // all state on one serial queue (Unit 4)
    public struct Config: Sendable {
        public var watchdogInterval: TimeInterval = 1.0
        public var idleExitSeconds: Double = ThermikHelper.Limits.idleExitSeconds
        public var markerPath: String? = ThermikHelper.manualMarkerPath
        public init() {}
    }
    public var onIdleExit: (@Sendable () -> Void)?
    public init(fans: FanControlling, installKind: HelperInstallKind, config: Config = Config()) {}
    public func start() {}
    public func shutdown(reason: String) {}
    public func systemWillSleep() {}
    public func systemDidWake() {}
}
