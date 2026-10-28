// BootHistoryReader.swift — Thermik (MIT). OWNER: Unit 2.
// Why the Mac last booted / shut down / slept / woke (SYS §7). Every source is readable without root:
// undocumented sysctls (Apple Silicon), IOPMrootDomain properties, the DumpPanic breadcrumb, and on Intel/T2 the
// "Previous shutdown cause: N" kernel line from the unified log (one narrow `log show` window, once per boot).
import Foundation
import IOKit

enum BootHistoryReader {
    /// ~0.3 ms. `intelShutdownCause` comes from `IntelShutdownCauseCache` (nil on Apple Silicon).
    static func read(intelShutdownCause: Int? = nil) -> BootHistory {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { if rootDomain != 0 { IOObjectRelease(rootDomain) } }
        func pm<T>(_ key: String) -> T? { rootDomain == 0 ? nil : IOKitHelpers.property(rootDomain, key) }
        let uuid = trimmed(SysctlReader.string("kern.bootsessionuuid"))
        return BootHistory(bootTime: SysctlReader.timeval("kern.boottime"),
                           lastSleepTime: SysctlReader.timeval("kern.sleeptime"),
                           lastWakeTime: SysctlReader.timeval("kern.waketime"),
                           bootSessionUUID: uuid,
                           // e.g. " wdog,reset_in_1 rst_in,reset_in_1_deassert wdog,reset_in_1 ap_restart" (leading space)
                           shutdownReason: trimmed(SysctlReader.string("kern.shutdownreason")),
                           bootReason: trimmed(SysctlReader.string("kern.bootreason")),
                           wakeReason: trimmed(SysctlReader.string("kern.wakereason")) ?? trimmed(pm("Wake Reason")),
                           lastSleepReason: trimmed(pm("Last Sleep Reason")),        // "Software Sleep", "Clamshell Sleep", …
                           wakeType: trimmed(pm("Wake Type")),                       // "UserActivity Assertion", …
                           lidClosed: (pm("AppleClamshellState") as NSNumber?)?.boolValue,
                           panicLogPath: uuid.flatMap(panicLogPath(bootSession:)),
                           intelShutdownCause: intelShutdownCause)
    }

    /// `/var/db/com.apple.DumpPanic.panicLogPathBreadcrumb` (0644): plist `{ <boot session UUID>: <panic report path or ""> }`.
    /// A non-empty value means this boot followed a kernel panic.
    static func panicLogPath(bootSession uuid: String) -> String? {
        guard let data = FileManager.default.contents(atPath: "/var/db/com.apple.DumpPanic.panicLogPathBreadcrumb"),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return trimmed(plist[uuid] as? String)
    }

    /// Intel / T2 only: `log show` over boot − 60 s … boot + 5 min for "Previous shutdown cause: N" (5–10 s, off-main via
    /// `ProcessRunner`). Default-level kernel messages rotate out of the unified log after a few days, so this is run on
    /// the first launch after each boot and cached. Apple Silicon Macs never log this line.
    static func queryIntelShutdownCause(bootTime: Date) async -> Int? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current                         // `log show` interprets --start/--end in local time
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let args = ["show", "--style", "compact",
                    "--start", f.string(from: bootTime.addingTimeInterval(-60)),
                    "--end", f.string(from: bootTime.addingTimeInterval(300)),
                    "--predicate", "eventMessage CONTAINS \"Previous shutdown cause\""]
        guard let data = await ProcessRunner.run("/usr/bin/log", args, timeout: 30) else { return nil }
        return parseIntelShutdownCause(String(decoding: data, as: UTF8.self))
    }

    /// "… Previous shutdown cause: -128" → -128 (the last match wins).
    static func parseIntelShutdownCause(_ text: String) -> Int? {
        let marker = "Previous shutdown cause:"
        guard let r = text.range(of: marker, options: .backwards) else { return nil }
        let tail = text[r.upperBound...].drop { $0 == " " || $0 == "\t" }
        let number = tail.prefix { $0 == "-" || ($0.isASCII && $0.isNumber) }
        return Int(number)
    }

    private static func trimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// UserDefaults cache of the Intel shutdown cause, keyed by `kern.bootsessionuuid` (SPEC §2.11 keys
/// `diag.lastBootSession` / `diag.intelShutdownCause`), so the slow `log show` query runs once per boot.
enum IntelShutdownCauseCache {
    static let sessionKey = "diag.lastBootSession"
    static let causeKey = "diag.intelShutdownCause"

    enum Lookup: Equatable {
        case hit(Int?)        // already queried for this boot (nil = the log had no such line)
        case miss
    }

    static func lookup(bootSession uuid: String?, defaults: UserDefaults = .standard) -> Lookup {
        guard let uuid, defaults.string(forKey: sessionKey) == uuid else { return .miss }
        return .hit(defaults.object(forKey: causeKey) as? Int)
    }

    static func store(_ cause: Int?, bootSession uuid: String, defaults: UserDefaults = .standard) {
        defaults.set(uuid, forKey: sessionKey)
        if let cause { defaults.set(cause, forKey: causeKey) } else { defaults.removeObject(forKey: causeKey) }
    }
}
