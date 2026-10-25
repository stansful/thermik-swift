// MockFanHelperClient.swift — Thermik (MIT). OWNER: Unit 0 (frozen). Demo-mode helper: accepts every command,
// clamps to the demo fan range, never talks XPC. Also `UnavailableFanHelperClient` for "no helper" states.
import Foundation
import ThermikHelperShared

final class MockFanHelperClient: FanHelperClient, @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [Int: Double] = [:]
    private let minRPM = 1350.0, maxRPM = 5777.0

    func hello() async throws -> HelperInfo {
        HelperInfo(protocolVersion: ThermikHelper.protocolVersion, helperVersion: "demo", helperBuild: "0", pid: 0,
                   installKind: .development, fanCount: 2, scheme: "demo")
    }
    func state() async throws -> HelperState {
        let t = lock.withLock { targets }
        let fans = (0..<2).map { i in
            HelperFanState(index: i, minRPM: minRPM, maxRPM: maxRPM, actualRPM: t[i] ?? minRPM, targetRPM: t[i] ?? minRPM,
                           modeRaw: t[i] == nil ? 0 : 1, ownedByThermik: t[i] != nil, appliedRPM: t[i])
        }
        return HelperState(info: try await hello(), fans: fans, ftst: t.isEmpty ? 0 : 1, ftstSetByThermik: !t.isEmpty,
                           isControlling: !t.isEmpty, leaseRemainingSeconds: t.isEmpty ? nil : 10, safetyOverrideActive: false,
                           foreignControllerSuspected: false, sleeping: false, lastRevertReason: nil, lastRevertDate: nil)
    }
    func setFanTarget(_ index: Int, rpm: Double, leaseSeconds: Double) async throws -> Double {
        guard (0..<2).contains(index) else { throw NSError.thermikHelper(.fanNotFound, "no fan \(index)") }
        guard rpm.isFinite, rpm >= 0 else { throw NSError.thermikHelper(.invalidArgument, "rpm") }
        let r = min(max(rpm, minRPM), maxRPM).rounded()
        lock.withLock { targets[index] = r }
        return r
    }
    func setFanAutomatic(_ index: Int) async throws { _ = lock.withLock { targets.removeValue(forKey: index) } }
    func renewLease(seconds: Double) async throws -> Bool { lock.withLock { !targets.isEmpty } }
    func resetAllFans() async throws { lock.withLock { targets.removeAll() } }
    func uninstallLegacyHelper() async throws {}
    func resetAllFansBlocking(timeout: TimeInterval) { lock.withLock { targets.removeAll() } }
}

/// Used while the helper is not installed / not approved: every command fails with `notPermitted`.
final class UnavailableFanHelperClient: FanHelperClient, @unchecked Sendable {
    private func fail() -> NSError { NSError.thermikHelper(.notPermitted, "helper not available") }
    func hello() async throws -> HelperInfo { throw fail() }
    func state() async throws -> HelperState { throw fail() }
    func setFanTarget(_ index: Int, rpm: Double, leaseSeconds: Double) async throws -> Double { throw fail() }
    func setFanAutomatic(_ index: Int) async throws { throw fail() }
    func renewLease(seconds: Double) async throws -> Bool { throw fail() }
    func resetAllFans() async throws { throw fail() }
    func uninstallLegacyHelper() async throws { throw fail() }
    func resetAllFansBlocking(timeout: TimeInterval) {}
}
