// HelperConnection.swift — Thermik (MIT). App-side NSXPC client. UNIT 0 STUB; OWNER: Unit 4
// (port research/helper/skeleton/App/HelperConnection.swift; conform to FanHelperClient). Public API FROZEN.
import Foundation

public final class HelperConnection: FanHelperClient, @unchecked Sendable {
    public typealias Factory = @Sendable () -> NSXPCConnection
    /// (invalidated) → true: gone (re-check install status); false: interrupted (helper restarted; re-send targets).
    public var onDisconnect: (@Sendable (_ invalidated: Bool) -> Void)?
    public init(factory: @escaping Factory, helperRequirement: String?, timeout: Duration = .seconds(ThermikHelper.Limits.replyTimeoutSeconds)) {}
    public static func privileged(helperRequirement: String?) -> HelperConnection {
        HelperConnection(factory: { NSXPCConnection(machServiceName: ThermikHelper.machServiceName, options: .privileged) },
                         helperRequirement: helperRequirement)
    }
    public static func requirementForHelper(appIdentity: CodeIdentity?) -> String {
        if let team = appIdentity?.teamID, !team.isEmpty {
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(ThermikHelper.helperSigningIdentifier)\""
        }
        return "identifier \"\(ThermikHelper.helperSigningIdentifier)\""
    }
    public func reset() {}
    private func unavailable() -> NSError { NSError.thermikHelper(.notPermitted, "not implemented (Unit 4)") }
    public func hello() async throws -> HelperInfo { throw unavailable() }
    public func state() async throws -> HelperState { throw unavailable() }
    public func setFanTarget(_ index: Int, rpm: Double, leaseSeconds: Double) async throws -> Double { throw unavailable() }
    public func setFanAutomatic(_ index: Int) async throws { throw unavailable() }
    public func renewLease(seconds: Double) async throws -> Bool { throw unavailable() }
    public func resetAllFans() async throws { throw unavailable() }
    public func uninstallLegacyHelper() async throws { throw unavailable() }
    public func resetAllFansBlocking(timeout: TimeInterval) {}
}
