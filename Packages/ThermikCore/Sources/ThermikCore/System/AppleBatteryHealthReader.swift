// AppleBatteryHealthReader.swift — Thermik (MIT). OWNER: Unit 2.
// Apple's own "Maximum Capacity" and condition, from `system_profiler SPPowerDataType -json` (SYS §2.3).
// ~125 ms (process spawn): launch + every 6 h, cached by SystemSampler. JSON values are not localized.
import Foundation

enum AppleBatteryHealthReader {
    /// nil when the tool fails or reports no battery.
    static func read(permanentFailureStatus: Int?) async -> AppleBatteryHealth? {
        guard let data = await ProcessRunner.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"], timeout: 20)
        else { return nil }
        return parse(data, permanentFailureStatus: permanentFailureStatus)
    }

    /// `SPPowerDataType[] › sppower_battery_health_info`:
    /// `sppower_battery_health_maximum_capacity` "100 %" (NBSP) and `sppower_battery_health` "Good".
    /// Serial numbers present in the same JSON are never read.
    static func parse(_ data: Data, permanentFailureStatus: Int?) -> AppleBatteryHealth? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]],
              let info = items.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first
        else { return nil }
        let raw = (info["sppower_battery_health"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppleBatteryHealth(maximumCapacityPercent: percent(info["sppower_battery_health_maximum_capacity"]),
                                  conditionRaw: raw,
                                  condition: condition(raw: raw, permanentFailureStatus: permanentFailureStatus))
    }

    /// "100 %" → 100 (only ASCII digits: the separator is a no-break space).
    static func percent(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        guard let s = any as? String else { return nil }
        let digits = s.filter { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// `PermanentFailureStatus ≠ 0` wins. "Good" (macOS 11+) / "Normal" (older) → normal; any other non-empty
    /// condition ("Service Recommended", older "Replace Soon" / "Replace Now" / "Service Battery") → service.
    static func condition(raw: String?, permanentFailureStatus: Int?) -> BatteryCondition {
        if let pf = permanentFailureStatus, pf != 0 { return .permanentFailure }
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return .unknown }
        switch raw {
        case "good", "normal": return .normal
        default: return .serviceRecommended
        }
    }
}
