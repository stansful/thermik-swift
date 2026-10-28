// ShutdownClassifier.swift — Thermik (MIT). OWNER: Unit 2. API FROZEN (`classify`); `classify(reason:)` and
// `intelCodeDescription(_:)` are additive.
// Conservative token classifier for kern.shutdownreason (+ Intel "Previous shutdown cause" codes), SYS §7.
// Apple documents neither vocabulary: the verdict is a heuristic and the UI always shows the raw string next to it.
import Foundation

public enum ShutdownClassifier {
    /// Order (SPEC §2.7): panic breadcrumb → `kern.shutdownreason` tokens → Intel cause code → `.unknown`.
    public static func classify(_ boot: BootHistory) -> ShutdownVerdict {
        if let p = boot.panicLogPath, !p.isEmpty { return .kernelPanic }
        if let r = boot.shutdownReason, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return classify(reason: r) }
        if let code = boot.intelShutdownCause { return .intelCode(code) }
        return .unknown
    }

    /// Case-insensitive token rules for a `kern.shutdownreason` string (space/comma separated, e.g.
    /// "wdog,reset_in_1 rst_in,reset_in_1_deassert wdog,reset_in_1 ap_restart"):
    /// `panic` → kernel panic; `ap_restart` → normal restart; `ap_shutdown` / `ap_poweroff` → normal shutdown;
    /// `button` / `pwr_btn` → forced; `therm` → thermal; `batt` / `uvlo` / `brownout` → power loss;
    /// `wdog` → watchdog **only if no `ap_*` token** is present (a plain software restart on M4 Max / macOS 27 reports
    /// both `wdog` and `ap_restart`; calling that a watchdog reset is the known false positive); anything else → `.other`.
    public static func classify(reason: String) -> ShutdownVerdict {
        let tokens = reason.lowercased()
            .split { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" || $0 == ";" }
            .map(String.init)
        guard !tokens.isEmpty else { return .unknown }
        func has(_ needles: String...) -> Bool { tokens.contains { t in needles.contains { t.contains($0) } } }
        if has("panic") { return .kernelPanic }
        if has("ap_restart") { return .normalRestart }
        if has("ap_shutdown", "ap_poweroff") { return .normalShutdown }
        if has("button", "pwr_btn") { return .forced }
        if has("therm") { return .thermal }
        if has("batt", "uvlo", "brownout") { return .powerLoss }
        if has("wdog"), !tokens.contains(where: { $0.hasPrefix("ap_") }) { return .watchdog }
        return .other
    }

    /// Localized meaning of an Intel / T2 "Previous shutdown cause" code (community-sourced table, SYS §7.2:
    /// George Garside "shutdown causes", Eclectic Light "Mac shutdown and sleep cause codes"). nil for unlisted codes.
    /// Resolved against the app's String Catalog (main bundle); English elsewhere.
    public static func intelCodeDescription(_ code: Int) -> String? {
        switch code {
        case 7: String(localized: "CPU thread error")
        case 6: String(localized: "Unknown cause")
        case 5: String(localized: "Normal shutdown (user)")
        case 3: String(localized: "Hard shutdown (power button or forced)")
        case 2: String(localized: "Power supply disconnected")
        case 1: String(localized: "Normal restart")
        case 0: String(localized: "Power lost (battery or adapter disconnected)")
        case -3: String(localized: "Multiple temperature sensors over limit")
        case -14: String(localized: "Electricity spike or surge")
        case -20: String(localized: "Shutdown initiated by the T2 chip (BridgeOS)")
        case -60: String(localized: "Battery fully drained")
        case -61: String(localized: "Watchdog: unresponsive app, shutdown")
        case -62: String(localized: "Watchdog: unresponsive app, restart")
        case -64: String(localized: "Kernel panic")
        case -71: String(localized: "Memory over temperature")
        case -74: String(localized: "Battery over temperature")
        case -75: String(localized: "Power adapter communication problem")
        case -78: String(localized: "Incorrect current from the power adapter")
        case -79: String(localized: "Incorrect current from the battery")
        case -81: String(localized: "Thermal shutdown (over-temperature)")
        case -86: String(localized: "Heat sink over temperature")
        case -95: String(localized: "CPU over temperature")
        case -100: String(localized: "Power supply over temperature")
        case -101: String(localized: "Display over temperature")
        case -102: String(localized: "Overvoltage")
        case -103: String(localized: "Battery cell under-voltage")
        case -104: String(localized: "Unknown battery fault")
        case -127: String(localized: "Forced shutdown by the PMU/SMC")
        case -128: String(localized: "Unknown cause (possibly memory-related)")
        default: nil
        }
    }
}
