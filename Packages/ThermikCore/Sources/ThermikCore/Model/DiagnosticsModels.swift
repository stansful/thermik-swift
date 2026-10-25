// DiagnosticsModels.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). Free hardware diagnostics (TG: paid).
// Core returns STRUCTURED findings; the app localizes them (no UI strings in Core).
import Foundation

public enum DiagnosticKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case lastShutdown, fans, sensors, battery, thermal, storage, helper, smc
    public var id: String { rawValue }
}

public enum DiagnosticStatus: Int, Sendable, Comparable, Codable {
    case ok = 0, info, unknown, warning, error
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum HelperHealth: Sendable, Equatable {
    case ready(version: String)
    case notInstalled, requiresApproval, needsUpgrade
    case unreachable(String)
    case foreignController(String?)
    case notApplicable                       // fanless
}

public enum DiagnosticFinding: Sendable, Equatable {
    case shutdown(ShutdownVerdict, panicLog: Bool)
    case fansOK(count: Int)
    case fanless
    case fansStalled([Int])                  // 0 rpm while commanded above Mn for > 30 s (not "off by macOS")
    case fansNotReachingTarget([Int])        // |actual − target| > 25 % for > 60 s
    case sensorsOK(count: Int)
    case sensorsSuspect([SensorID])          // stuck > 10 min, out of range, invalid while siblings valid
    case battery(BatteryCondition, healthPercent: Double?, cycles: Int?, ratedCycles: Int?)
    case noBattery
    case thermal(ThermalPressure, eventsToday: Int)
    case storage(percentUsed: Int?, temperatureC: Int?, criticalWarning: Bool)
    case helper(HelperHealth)
    case smc(available: Bool, keyCount: Int, catalog: CatalogStatus)
    case unknown
}

/// Raw technical detail shown verbatim in an expandable "Details" area (not localized), e.g.
/// ("kern.shutdownreason", "wdog,reset_in_1 … ap_restart").
public struct DiagnosticDetail: Sendable, Equatable, Hashable {
    public var label: String
    public var value: String
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

public struct DiagnosticItem: Sendable, Equatable, Identifiable {
    public var id: DiagnosticKind
    public var status: DiagnosticStatus
    public var finding: DiagnosticFinding
    public var details: [DiagnosticDetail]
    public var updated: Date
    public init(id: DiagnosticKind, status: DiagnosticStatus, finding: DiagnosticFinding, details: [DiagnosticDetail], updated: Date) {
        self.id = id; self.status = status; self.finding = finding; self.details = details; self.updated = updated
    }
}

/// Slow/rare context for the evaluators (assembled by DiagnosticsStore).
public struct DiagnosticsContext: Sendable {
    public var slow: SlowSystemData
    public var battery: BatterySnapshot?
    public var helper: HelperHealth
    public var inventory: SensorInventory?
    public var pressure: ThermalPressure
    public var pressureEventsToday: Int
    public init(slow: SlowSystemData, battery: BatterySnapshot?, helper: HelperHealth, inventory: SensorInventory?,
                pressure: ThermalPressure, pressureEventsToday: Int) {
        self.slow = slow; self.battery = battery; self.helper = helper; self.inventory = inventory
        self.pressure = pressure; self.pressureEventsToday = pressureEventsToday
    }
}
