// SMCClientInspector.swift — Thermik (MIT)
//
// Read-only detection of OTHER fan-control apps. Two independent signals:
//   1. SMC state: Ftst == 1, any mode key == 1, or FS! != 0 while Thermik's
//      helper does not own control  -> somebody else is forcing fans.
//   2. IORegistry: every open AppleSMC user client ("AppleSMCClient", child of
//      AppleSMCKeysEndpoint on Apple Silicon / AppleSMC on Intel) carries an
//      "IOUserClientCreator" = "pid <n>, <p_comm (16 chars max)>" property.
// Signal 1 decides; signal 2 only names the culprit in the UI.
//
// Naming a client (no vendor identifiers are hard-coded):
//   a. its process name starts with a known fan-control APP name (`knownFanControllers`), or
//   b. its executable lives in /Library/PrivilegedHelperTools/, the location of third-party root helpers
//      (SMJobBless and admin-script installers; macOS itself installs nothing there). Writing the SMC needs
//      root, so such a helper holding an SMC connection is the usual culprit. It is named by its executable's
//      file name (`proc_pidpath`, path only: no file is opened or read). Thermik's own helper is skipped.
//      Other root helpers also talk to the SMC (verified here: a battery charge limiter's helper), so helpers
//      whose file name contains "fan" are listed before the rest.
// Monitoring-only apps without a root helper are not reported unless (a) lists them.

import Foundation
import IOKit

public struct SMCClientInfo: Sendable, Equatable {
    public let pid: Int32
    public let processName: String   // truncated to 15/16 chars by the kernel (p_comm)
}

public enum SMCClientInspector {
    /// Process-name prefixes of known fan-control APPS (heuristic, for UI text only).
    /// Their privileged helpers are found by location instead (see the header).
    public static let knownFanControllers: [(prefix: String, product: String)] = [
        ("TG Pro", "TG Pro"), ("Macs Fan Control", "Macs Fan Control"), ("Stats", "Stats"),
        ("smcFanControl", "smcFanControl"), ("FanBar", "FanBar"), ("fanctl", "fanctl"),
        ("macfand", "MacFan"), ("fand", "MacFanOptimizer"),
    ]

    /// Install directory of third-party privileged helpers (launchd daemons).
    static let privilegedHelperDirectory = "/Library/PrivilegedHelperTools/"

    /// Executable file names of Thermik's own helper: legacy install (`ThermikHelper.label`, ThermikHelperShared)
    /// and the copy embedded in the app bundle (SMAppService). ThermikSMC cannot import ThermikHelperShared.
    static let ownHelperNames: Set<String> = ["app.thermik.helper", "thermik-helper"]

    public static func openClients() -> [SMCClientInfo] {
        var result: [SMCClientInfo] = []
        for className in ["AppleSMCKeysEndpoint", "AppleSMC"] {
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iter) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iter) }
            var service = IOIteratorNext(iter)
            while service != 0 {
                result += clients(under: service)
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }
            if !result.isEmpty { break }
        }
        return result
    }

    private static func clients(under service: io_object_t) -> [SMCClientInfo] {
        var out: [SMCClientInfo] = []
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(children) }
        var child = IOIteratorNext(children)
        while child != 0 {
            if IOObjectConformsTo(child, "AppleSMCClient") != 0,
               let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
               let info = parse(creator) {
                out.append(info)
            }
            IOObjectRelease(child)
            child = IOIteratorNext(children)
        }
        return out
    }

    /// "pid 858, Example App" -> (858, "Example App")
    static func parse(_ s: String) -> SMCClientInfo? {
        guard s.hasPrefix("pid "), let comma = s.firstIndex(of: ",") else { return nil }
        let pidStr = s[s.index(s.startIndex, offsetBy: 4)..<comma]
        guard let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)) else { return nil }
        let name = s[s.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return SMCClientInfo(pid: pid, processName: name)
    }

    /// Full executable path of a running process (`proc_pidpath`; works for root processes without privileges).
    static func executablePath(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }

    /// Name of the third-party privileged helper behind `pid`, or nil when it is not one (or is Thermik's own).
    static func privilegedHelperName(of pid: Int32) -> String? {
        guard let path = executablePath(of: pid), path.hasPrefix(privilegedHelperDirectory) else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || ownHelperNames.contains(name) ? nil : name
    }

    /// Names of fan-control products that currently hold an SMC connection, most likely first: known apps,
    /// then third-party privileged helpers with "fan" in their file name, then the other privileged helpers.
    public static func suspectedFanControllers(excludingPID own: Int32 = getpid()) -> [String] {
        var products: [String] = []
        var fanHelpers: [String] = []
        var otherHelpers: [String] = []
        for c in openClients() where c.pid != own {
            if let hit = knownFanControllers.first(where: { c.processName.hasPrefix($0.prefix) }) {
                if !products.contains(hit.product) { products.append(hit.product) }
            } else if let helper = privilegedHelperName(of: c.pid) {
                if helper.range(of: "fan", options: .caseInsensitive) != nil {
                    if !fanHelpers.contains(helper) { fanHelpers.append(helper) }
                } else if !otherHelpers.contains(helper) {
                    otherHelpers.append(helper)
                }
            }
        }
        return products + fanHelpers + otherHelpers
    }
}
