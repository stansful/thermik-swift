// ShutdownClassifier.swift — Thermik (MIT). Shutdown classification.
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
        let tokens = tokens(in: reason)
        guard !tokens.isEmpty else { return .unknown }
        if let verdict = softwareVerdict(tokens) { return verdict }
        return hardwareVerdict(tokens)
    }

    private static func tokens(in reason: String) -> [String] {
        reason.lowercased()
            .split { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" || $0 == ";" }
            .map(String.init)
    }

    private static func softwareVerdict(_ tokens: [String]) -> ShutdownVerdict? {
        if has("panic", in: tokens) { return .kernelPanic }
        if has("ap_restart", in: tokens) { return .normalRestart }
        if has("ap_shutdown", "ap_poweroff", in: tokens) { return .normalShutdown }
        return nil
    }

    private static func hardwareVerdict(_ tokens: [String]) -> ShutdownVerdict {
        if has("button", "pwr_btn", in: tokens) { return .forced }
        if has("therm", in: tokens) { return .thermal }
        if has("batt", "uvlo", "brownout", in: tokens) { return .powerLoss }
        if has("wdog", in: tokens), !tokens.contains(where: { $0.hasPrefix("ap_") }) { return .watchdog }
        return .other
    }

    private static func has(_ needles: String..., in tokens: [String]) -> Bool {
        tokens.contains { token in needles.contains { token.contains($0) } }
    }

    /// Localized meaning of an Intel / T2 "Previous shutdown cause" code (community-sourced table, SYS §7.2:
    /// George Garside "shutdown causes", Eclectic Light "Mac shutdown and sleep cause codes"). nil for unlisted codes.
    /// Resolved against the app's String Catalog (main bundle); English elsewhere.
    public static func intelCodeDescription(_ code: Int) -> String? {
        if let description = userCodeDescription(code) { return description }
        if let description = thermalCodeDescription(code) { return description }
        if let description = batteryCodeDescription(code) { return description }
        if let description = powerCodeDescription(code) { return description }
        return systemCodeDescription(code)
    }

    private static func userCodeDescription(_ code: Int) -> String? {
        switch code {
        case 7: String(localized: "CPU thread error")
        case 6: String(localized: "Unknown cause")
        case 5: String(localized: "Normal shutdown (user)")
        case 3: String(localized: "Hard shutdown (power button or forced)")
        case 2: String(localized: "Power supply disconnected")
        case 1: String(localized: "Normal restart")
        case 0: String(localized: "Power lost (battery or adapter disconnected)")
        default: nil
        }
    }

    private static func thermalCodeDescription(_ code: Int) -> String? {
        if let description = sensorThermalCodeDescription(code) { return description }
        return componentThermalCodeDescription(code)
    }

    private static func sensorThermalCodeDescription(_ code: Int) -> String? {
        switch code {
        case -3: String(localized: "Multiple temperature sensors over limit")
        case -71: String(localized: "Memory over temperature")
        case -74: String(localized: "Battery over temperature")
        case -81: String(localized: "Thermal shutdown (over-temperature)")
        default: nil
        }
    }

    private static func componentThermalCodeDescription(_ code: Int) -> String? {
        switch code {
        case -86: String(localized: "Heat sink over temperature")
        case -95: String(localized: "CPU over temperature")
        case -100: String(localized: "Power supply over temperature")
        case -101: String(localized: "Display over temperature")
        default: nil
        }
    }

    private static func batteryCodeDescription(_ code: Int) -> String? {
        switch code {
        case -60: String(localized: "Battery fully drained")
        case -79: String(localized: "Incorrect current from the battery")
        case -103: String(localized: "Battery cell under-voltage")
        case -104: String(localized: "Unknown battery fault")
        default: nil
        }
    }

    private static func powerCodeDescription(_ code: Int) -> String? {
        switch code {
        case -14: String(localized: "Electricity spike or surge")
        case -75: String(localized: "Power adapter communication problem")
        case -78: String(localized: "Incorrect current from the power adapter")
        case -102: String(localized: "Overvoltage")
        default: nil
        }
    }

    private static func systemCodeDescription(_ code: Int) -> String? {
        switch code {
        case -20: String(localized: "Shutdown initiated by the T2 chip (BridgeOS)")
        case -61: String(localized: "Watchdog: unresponsive app, shutdown")
        case -62: String(localized: "Watchdog: unresponsive app, restart")
        case -64: String(localized: "Kernel panic")
        case -127: String(localized: "Forced shutdown by the PMU/SMC")
        case -128: String(localized: "Unknown cause (possibly memory-related)")
        default: nil
        }
    }
}
