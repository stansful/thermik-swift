// HelperRuntime.swift — Thermik (MIT). HELPER ONLY. OWNER: Unit 4.
// Process-level facts the helper's main.swift wires together (SPEC §2.6.5): loggers, install-kind detection,
// the embedded version info, and the fallback controller used when the SMC cannot be opened.
import Foundation
import os
import ThermikSMC
import ThermikSMCWriter
import ThermikHelperShared

// Logging (HELP §6): subsystem "app.thermik.helper"; `.notice` for state transitions, `.error` for failures,
// `.info` for chatty detail. Only numbers, fan indices and reasons are public.
let serviceLog = Logger(subsystem: ThermikHelper.label, category: "service")
let xpcLog = Logger(subsystem: ThermikHelper.label, category: "xpc")
let securityLog = Logger(subsystem: ThermikHelper.label, category: "security")
let powerLog = Logger(subsystem: ThermikHelper.label, category: "power")
let lifecycleLog = Logger(subsystem: ThermikHelper.label, category: "lifecycle")

public enum HelperRuntime {
    /// Exit status when the real (non-mock) helper is not started as root: EX_NOPERM.
    public static let notRootExitCode: Int32 = 77

    /// The lifecycle logger, for main.swift.
    public static var log: Logger { lifecycleLog }

    /// Resolved path of the running executable.
    public static var executablePath: String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return (raw as NSString).resolvingSymlinksInPath
    }

    /// `/Library/PrivilegedHelperTools/app.thermik.helper` → `.legacy`; inside `*.app/Contents/MacOS/` →
    /// `.appService`; anything else (a build directory, `swift run`) → `.development` (SPEC §2.6.5 step 2).
    public static func detectInstallKind(executablePath path: String = executablePath) -> HelperInstallKind {
        if path == ThermikHelper.Legacy.helperPath { return .legacy }
        if path.contains(".app/Contents/MacOS/") { return .appService }
        return .development
    }

    /// CFBundleShortVersionString / CFBundleVersion (= HELPER_BUILD_VERSION) from the embedded __info_plist.
    public static var version: (short: String, build: String) {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String ?? "0", info["CFBundleVersion"] as? String ?? "0")
    }

    /// Crash marker location for `--mock` runs: a non-root process cannot write /var/run, and a mock marker must
    /// never be mistaken for a real one.
    public static var mockMarkerPath: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("\(ThermikHelper.label).mock.manual")
    }
}

/// FanControlling for a Mac whose SMC cannot be opened: no fans, every write is refused (`notControllable`).
/// Keeps the daemon answering `hello`/`getState` instead of crash-looping under KeepAlive.
public final class UnavailableFanController: FanControlling {
    public let profile = FanHardwareProfile.none
    public let isControlling = false
    public let ownedFans: Set<Int> = []
    public let ftstSetByUs = false
    public let appliedRPM: [Int: Double] = [:]
    public init() {}
    public func fanStates() -> [HelperFanState] { [] }
    public func ftstValue() -> Int? { nil }
    public func setManual(_ index: Int, targetRPM: Double) throws -> Double { throw FanWriteError.notControllable }
    public func setAutomatic(_ index: Int) throws { throw FanWriteError.notControllable }
    @discardableResult public func restoreAll(force: Bool, reason: String) -> [String] { [] }
    public func adoptPersistedState(ftstSetByUs: Bool) {}
    public func reclaimedFans() -> [Int] { [] }
    public func foreignControlSuspected() -> Bool { false }
    public func evaluateSafety() -> SafetyVerdict { .normal(hottestC: nil) }
    public func currentHottestDieC() -> Double? { nil }
}
