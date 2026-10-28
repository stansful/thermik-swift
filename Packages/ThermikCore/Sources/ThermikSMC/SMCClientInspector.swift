// SMCClientInspector.swift — Thermik (MIT)
//
// Read-only detection of OTHER fan-control apps. Two independent signals:
//   1. SMC state: Ftst == 1, any mode key == 1, or FS! != 0 while Thermik's
//      helper does not own control  -> somebody else is forcing fans.
//   2. IORegistry: every open AppleSMC user client ("AppleSMCClient", child of
//      AppleSMCKeysEndpoint on Apple Silicon / AppleSMC on Intel) carries an
//      "IOUserClientCreator" = "pid <n>, <p_comm (16 chars max)>" property.
// Signal 1 DECIDES (FanReader.snapshot(...).anyManual); signal 2 only NAMES the culprit in the UI.
//
// Many processes hold an SMC connection without controlling fans (systemstats, PowerChime, Siri, and
// third-party root helpers such as a battery charge limiter — verified on the development Mac: AlDente's helper).
// Holding a connection is therefore never evidence, and a client is named ONLY when it is positively known
// to be a fan controller:
//   a. its process name matches a known fan-control APP (`knownFanControllers[].processNames`), or
//   b. its executable is a privileged helper (/Library/PrivilegedHelperTools/<launchd label>, found with
//      proc_pidpath — a path lookup, no file is opened) whose label is a known fan-control helper
//      (`knownFanControllers[].helperLabels`), or
//   c. that helper's label contains "fan" (an unknown fan tool) and is not on the non-fan list.
// When proc_pidpath fails, a truncated p_comm (15–16 chars) is matched as a prefix of the known helper labels.
// Everything else — including every helper on `knownNonFanClients` — is never reported.
// Labels are public identifiers (launchd plist names), listed for interoperability only.

import Foundation
import IOKit

public struct SMCClientInfo: Sendable, Equatable {
    public let pid: Int32
    public let processName: String   // truncated to 15/16 chars by the kernel (p_comm)
}

/// A third-party product that can force the fans.
public struct KnownFanController: Sendable, Equatable {
    public let product: String
    /// p_comm of the app process (exact, or a prefix when `processPrefix` is true).
    public let processNames: [String]
    public let processPrefix: Bool
    /// launchd labels of its privileged SMC helper (= file name in /Library/PrivilegedHelperTools and
    /// /Library/LaunchDaemons/<label>.plist).
    public let helperLabels: [String]
    public init(product: String, processNames: [String], processPrefix: Bool = true, helperLabels: [String] = []) {
        self.product = product; self.processNames = processNames; self.processPrefix = processPrefix
        self.helperLabels = helperLabels
    }
}

/// How one SMC client was classified (the probe prints this; the UI only uses the names).
public enum SMCClientClassification: Sendable, Equatable, CustomStringConvertible {
    case fanControllerApp(product: String)
    case fanControllerHelper(product: String, label: String)
    case unknownFanHelper(label: String)          // "fan" in a third-party helper label
    case nonFanHelper(label: String)              // third-party root helper that is NOT a fan controller (never reported)
    case thermikHelper
    case other                                    // system daemons, monitoring apps, …

    public var reportedName: String? {
        switch self {
        case .fanControllerApp(let p), .fanControllerHelper(let p, _): return p
        case .unknownFanHelper(let l): return l
        case .nonFanHelper, .thermikHelper, .other: return nil
        }
    }

    public var description: String {
        switch self {
        case .fanControllerApp(let p): return "fan-control app (\(p))"
        case let .fanControllerHelper(p, l): return "fan-control helper \(l) (\(p))"
        case .unknownFanHelper(let l): return "unknown fan helper \(l)"
        case .nonFanHelper(let l): return "privileged helper \(l) — not a fan controller, ignored"
        case .thermikHelper: return "Thermik helper"
        case .other: return "other (ignored)"
        }
    }
}

public enum SMCClientInspector {
    /// Known fan-control products (public names and launchd labels).
    public static let knownFanControllers: [KnownFanController] = [
        KnownFanController(product: "TG Pro", processNames: ["TG Pro"],
                           helperLabels: ["com.tunabellysoftware.TGFanHelper"]),
        KnownFanController(product: "Macs Fan Control", processNames: ["Macs Fan Control"],
                           helperLabels: ["com.crystalidea.macsfancontrol.smcwrite"]),
        KnownFanController(product: "Stats", processNames: ["Stats"], processPrefix: false,
                           helperLabels: ["eu.exelban.Stats.SMC.Helper"]),
        KnownFanController(product: "smcFanControl", processNames: ["smcFanControl"]),
        KnownFanController(product: "FanBar", processNames: ["FanBar"], helperLabels: ["com.local.fanctl"]),
        KnownFanController(product: "fanctl", processNames: ["fanctl"], processPrefix: false),
        KnownFanController(product: "Mac Fan Optimizer", processNames: ["macfand", "fand"], processPrefix: false),
    ]

    /// Label prefixes of root helpers that are known to open the SMC for something other than fans.
    /// Never reported as fan controllers, even if a future label contained "fan".
    public static let knownNonFanClients: [String] = [
        "com.apphousekitchen.",        // AlDente (battery charge limiter) — present on the development Mac
        "me.mhaeuser.",                // Battery Toolkit (battery charge limiter)
    ]

    /// Install directory of third-party privileged helpers (launchd daemons).
    static let privilegedHelperDirectory = "/Library/PrivilegedHelperTools/"
    static let launchDaemonsDirectory = "/Library/LaunchDaemons/"

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

    // MARK: Classification (pure; `executablePath` is injected so the rules can be exercised offline)

    /// Classifies one client. `executablePath` is the result of `proc_pidpath` (nil when unavailable).
    public static func classify(processName: String, executablePath: String?) -> SMCClientClassification {
        if let app = knownFanControllers.first(where: { k in
            k.processNames.contains { k.processPrefix ? processName.hasPrefix($0) : processName == $0 }
        }) {
            return .fanControllerApp(product: app.product)
        }
        if let path = executablePath {
            guard path.hasPrefix(privilegedHelperDirectory) else { return .other }
            return classifyHelper(label: (path as NSString).lastPathComponent)
        }
        // No path: a helper's p_comm is its label truncated to 15–16 characters ("com.tunabellysof").
        if processName.count >= 15 {
            if ownHelperNames.contains(where: { $0.hasPrefix(processName) }) { return .thermikHelper }
            if knownNonFanClients.contains(where: { processName.hasPrefix($0) || $0.hasPrefix(processName) }) {
                return .nonFanHelper(label: processName)
            }
            for k in knownFanControllers {
                if let label = k.helperLabels.first(where: { $0.hasPrefix(processName) }) {
                    return .fanControllerHelper(product: k.product, label: label)
                }
            }
        }
        return .other
    }

    /// Classifies a privileged helper by its launchd label (= executable file name).
    public static func classifyHelper(label: String) -> SMCClientClassification {
        if label.isEmpty { return .other }
        if ownHelperNames.contains(label) { return .thermikHelper }
        if knownNonFanClients.contains(where: { label.hasPrefix($0) }) { return .nonFanHelper(label: label) }
        for k in knownFanControllers where k.helperLabels.contains(label) {
            return .fanControllerHelper(product: k.product, label: label)
        }
        if label.range(of: "fan", options: .caseInsensitive) != nil { return .unknownFanHelper(label: label) }
        return .nonFanHelper(label: label)
    }

    /// Every open SMC client with its classification (probe / diagnostics).
    public static func classifiedClients(excludingPID own: Int32 = getpid()) -> [(client: SMCClientInfo, kind: SMCClientClassification)] {
        openClients().filter { $0.pid != own }.map { c in
            (c, classify(processName: c.processName, executablePath: executablePath(of: c.pid)))
        }
    }

    /// Names of fan-control products that currently hold an SMC connection, most likely first: known apps,
    /// then known fan-control helpers, then unknown helpers with "fan" in their label. Never a non-fan helper.
    /// Only call this when the SMC state already shows foreign forcing (signal 1); it costs ~1 ms of IORegistry
    /// walking, so callers rate-limit it (FanStore: at most every 10 s).
    public static func suspectedFanControllers(excludingPID own: Int32 = getpid()) -> [String] {
        var apps: [String] = []
        var helpers: [String] = []
        var unknown: [String] = []
        for (_, kind) in classifiedClients(excludingPID: own) {
            switch kind {
            case .fanControllerApp(let p): if !apps.contains(p) { apps.append(p) }
            case .fanControllerHelper(let p, _): if !helpers.contains(p) { helpers.append(p) }
            case .unknownFanHelper(let l): if !unknown.contains(l) { unknown.append(l) }
            case .nonFanHelper, .thermikHelper, .other: break
            }
        }
        var out = apps
        for n in helpers + unknown where !out.contains(n) { out.append(n) }
        return out
    }

    /// Known fan-control products whose launchd daemon plist is installed (presence only, the file is not read).
    /// Installed is not running: use it as a naming fallback only.
    public static func installedFanControlHelpers() -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for k in knownFanControllers where !out.contains(k.product) {
            if k.helperLabels.contains(where: { fm.fileExists(atPath: launchDaemonsDirectory + $0 + ".plist") }) {
                out.append(k.product)
            }
        }
        return out
    }
}
