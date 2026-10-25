// HelperManager.swift — Thermik (MIT). STUB by Unit 0; OWNER: Unit 4 (port research/helper/skeleton/App/HelperManager.swift).
// Public surface FROZEN.
import Foundation
import Observation
import ThermikCore
import ThermikHelperShared

@MainActor @Observable final class HelperManager {
    enum Mode: String, Sendable { case appService, legacy }
    enum State: Equatable, Sendable {
        case unknown
        case notInstalled
        case requiresApproval                         // user must flip the switch in Login Items
        case needsUpgrade(installed: String, bundled: String)
        case ready(HelperInfo)
        case unreachable(String)
    }

    private(set) var state: State = .unknown
    let mode: Mode
    let isDemo: Bool
    /// Known fan-control daemons installed on this Mac (plist presence only), e.g. ["TG Pro"].
    private(set) var conflictingHelpers: [String] = []
    private(set) var lastHelperState: HelperState?
    /// The client FanStore talks to. Replaced on (re)connect; MockFanHelperClient in demo mode.
    private(set) var client: any FanHelperClient

    init(demo: Bool) {
        isDemo = demo
        mode = .legacy
        client = demo ? MockFanHelperClient() : UnavailableFanHelperClient()
        if demo { state = .ready(HelperInfo(protocolVersion: ThermikHelper.protocolVersion, helperVersion: "demo", helperBuild: "0",
                                            pid: 0, installKind: .development, fanCount: 2, scheme: "demo")) }
    }

    var isReady: Bool { if case .ready = state { return true }; return false }

    /// nil when ready.
    var availability: HelperAvailability? {
        switch state {
        case .ready: return nil
        case .unknown: return .connecting
        case .notInstalled: return .notInstalled
        case .requiresApproval: return .requiresApproval
        case .needsUpgrade: return .needsUpgrade
        case .unreachable: return .unreachable
        }
    }

    var health: HelperHealth {
        switch state {
        case .ready(let i): return .ready(version: i.helperVersion)
        case .unknown, .unreachable: return .unreachable(String(describing: state))
        case .notInstalled: return .notInstalled
        case .requiresApproval: return .requiresApproval
        case .needsUpgrade: return .needsUpgrade
        }
    }

    func refresh() async {}
    func install() async throws {}
    func awaitApproval(timeout: Duration = .seconds(120)) async -> Bool { false }
    func upgrade() async throws {}
    func uninstall() async throws {}
    func openLoginItems() {}
    /// getState() → lastHelperState (Diagnostics, Fans page helper card).
    func fetchState() async {}
}
