// LogModels.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). CSV logging configuration & rows (SPEC §2.12).
import Foundation

public enum LogColumnGroup: String, Codable, Sendable, CaseIterable {
    case headline        // cpu_avg, cpu_hottest, gpu_avg, gpu_hottest, soc, memory, ssd, battery
    case fans            // fanN_rpm, fanN_target, fan_mode
    case power           // system_w, cpu_w, gpu_w, battery_w
    case usage           // cpu_usage, gpu_usage, mem_used_gb
    case thermal         // thermal_pressure
    case battery         // battery_pct, on_ac
    case sensors         // one column per chosen sensor (LogConfig.sensorIDs; empty = all visible)
    case events          // the event column (alerts, mode changes, sleep/wake, helper reverts)
}

public enum LogRotation: Codable, Sendable, Hashable {
    case daily                      // Thermik-YYYY-MM-DD.csv (default)
    case weekly                     // Thermik-YYYY-Www.csv
    case sizeMB(Int)                // Thermik-YYYY-MM-DD-HHMMSS.csv when the current file exceeds N MB
    case never                      // Thermik.csv, appended forever
}

public struct LogConfig: Codable, Sendable, Hashable {
    public var enabled = false
    /// Unsandboxed app → plain path (no security-scoped bookmark needed).
    public var folderPath: String = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/Thermik")
    public var intervalSeconds: Double = 10        // ≥ the sampling interval; 0 = every tick
    public var include: Set<LogColumnGroup> = [.headline, .fans, .power, .thermal, .battery, .events]
    public var sensorIDs: [SensorID] = []          // with .sensors; empty = all visible sensors
    public var rotation: LogRotation = .daily
    /// nil (default) = keep everything. Never delete without the user explicitly enabling this.
    public var retentionDays: Int? = nil
    public init() {}
}

public struct CSVColumn: Sendable, Hashable {
    public var id: String          // machine id: "cpu_avg", "fan0_rpm", "smc:Tp01"
    public var nameEN: String
    public var nameRU: String
    public init(id: String, nameEN: String, nameRU: String) { self.id = id; self.nameEN = nameEN; self.nameRU = nameRU }
}

public struct CSVLogHeader: Sendable, Hashable {
    public var modelIdentifier: String
    public var chip: String
    public var osVersion: String
    public var appVersion: String
    public var intervalSeconds: Double
    public var numericColumns: [CSVColumn]         // after "timestamp"; then "fan_mode" (if .fans) and "event" (if .events)
    public var includesFanMode: Bool
    public var includesEvents: Bool
    public init(modelIdentifier: String, chip: String, osVersion: String, appVersion: String, intervalSeconds: Double,
                numericColumns: [CSVColumn], includesFanMode: Bool, includesEvents: Bool) {
        self.modelIdentifier = modelIdentifier; self.chip = chip; self.osVersion = osVersion; self.appVersion = appVersion
        self.intervalSeconds = intervalSeconds; self.numericColumns = numericColumns
        self.includesFanMode = includesFanMode; self.includesEvents = includesEvents
    }
}

public struct CSVLogRow: Sendable {
    public var date: Date
    public var numbers: [Double?]                  // aligned with header.numericColumns; nil → empty cell
    public var fanMode: String?                    // "system" | "curve:balanced" | "fixed:50" | "max"
    public var events: [String]                    // machine tokens, joined with ";" (e.g. "alert:cpu_hottest>95")
    public init(date: Date, numbers: [Double?], fanMode: String?, events: [String]) {
        self.date = date; self.numbers = numbers; self.fanMode = fanMode; self.events = events
    }
}
