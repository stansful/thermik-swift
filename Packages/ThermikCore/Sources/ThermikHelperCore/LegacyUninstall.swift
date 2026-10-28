// LegacyUninstall.swift — Thermik (MIT). HELPER ONLY. OWNER: Unit 4.
// XPC `uninstallLegacyHelper` for legacy installs (HELP §4.3; SPEC §2.6.5 step 8): the root helper deletes its own
// fixed set of files — no path ever comes from the client (I14) — replies, then boots itself out. launchd's SIGTERM
// lands in main.swift's handler (restore + exit 0). The app needs no administrator password for this.
import Foundation
import ThermikHelperShared

public enum LegacyUninstall {
    /// Everything a legacy install created, removed in this order. Unlinking the running binary is fine.
    public static let installedPaths = [
        ThermikHelper.Legacy.plistPath,
        ThermikHelper.Legacy.trustFilePath,
        ThermikHelper.Legacy.supportDirectory,
        ThermikHelper.Legacy.helperPath,
    ]

    /// Seconds between the XPC reply and `launchctl bootout` (the reply must reach the app first).
    static let bootoutDelay: Double = 0.5
    /// If launchd has not stopped the helper by then, exit anyway (exit 0: KeepAlive does not relaunch).
    static let forcedExitDelay: Double = 5

    /// The self-uninstall hook for HelperXPCServer: non-nil only when this helper runs from the legacy location.
    /// Runs on the service's state queue after the fans were restored.
    public static func makeHandler(installKind: HelperInstallKind, service: HelperService) -> (@Sendable () throws -> Void)? {
        guard installKind == .legacy else { return nil }
        return { [service] in
            try removeInstalledFiles()
            lifecycleLog.notice("legacy helper files removed; booting out")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bootoutDelay) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                p.arguments = ["bootout", "system/\(ThermikHelper.label)"]
                do { try p.run() } catch {
                    lifecycleLog.error("launchctl bootout failed to start: \(error.localizedDescription, privacy: .public)")
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + forcedExitDelay) {
                service.shutdown(reason: "uninstall")
                lifecycleLog.notice("uninstalled; exiting")
                exit(0)
            }
        }
    }

    /// Removes the install's files. Missing files are fine; the launchd plist must be gone afterwards, otherwise
    /// launchd would start the (now missing) binary again at boot.
    static func removeInstalledFiles() throws {
        let fm = FileManager.default
        var failures: [String] = []
        for path in installedPaths where fm.fileExists(atPath: path) {
            do { try fm.removeItem(atPath: path) }
            catch { failures.append("\(path): \(error.localizedDescription)") }
        }
        if fm.fileExists(atPath: ThermikHelper.Legacy.plistPath) {
            throw NSError.thermikHelper(.internalError, "cannot remove the launchd plist: \(failures.joined(separator: "; "))")
        }
        if !failures.isEmpty { lifecycleLog.error("uninstall left files behind: \(failures.joined(separator: "; "), privacy: .public)") }
    }
}
