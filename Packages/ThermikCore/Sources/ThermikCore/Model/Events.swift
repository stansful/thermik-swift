// Events.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). In-app event log entries (Logs page, CSV event column).
import Foundation

public enum AppEventPayload: Sendable, Hashable {
    case alertRaised(ruleID: UUID, subject: AlertRule.Subject, value: Double?, sensorID: SensorID?)
    case alertCleared(ruleID: UUID)
    case fanModeChanged(FanModeChange)
    case helperReverted(reason: String)            // raw helper reason ("leaseExpired", "clientGone", …)
    case helperStatus(HelperAvailability?)         // nil = ready
    case safetyOverride(engaged: Bool, temperatureC: Double?)
    case systemWillSleep, systemDidWake
    case powerSourceChanged(PowerSourceKind)
    case thermalPressureChanged(ThermalPressure)
    case appLaunched(version: String)
    case error(String)

    /// Machine token for the CSV event column.
    public var csvToken: String {
        switch self {
        case .alertRaised(_, let s, let v, let id): return "alert:\(s)\(v.map { String(format: "=%.1f", $0) } ?? "")\(id.map { "@\($0)" } ?? "")"
        case .alertCleared: return "alert_cleared"
        case .fanModeChanged(let c): return "mode:\(c.from.rawValue)->\(c.to.rawValue)(\(c.reason.rawValue))"
        case .helperReverted(let r): return "helper_revert:\(r)"
        case .helperStatus(let s): return "helper:\(s?.rawValue ?? "ready")"
        case .safetyOverride(let on, _): return on ? "safety_on" : "safety_off"
        case .systemWillSleep: return "sleep"
        case .systemDidWake: return "wake"
        case .powerSourceChanged(let k): return "power:\(k.rawValue)"
        case .thermalPressureChanged(let p): return "pressure:\(p.rawValue)"
        case .appLaunched(let v): return "launch:\(v)"
        case .error(let e): return "error:\(e.replacingOccurrences(of: ",", with: " "))"
        }
    }
}

public struct AppEvent: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let date: Date
    public let payload: AppEventPayload
    public init(id: UUID = UUID(), date: Date = Date(), payload: AppEventPayload) { self.id = id; self.date = date; self.payload = payload }
}
