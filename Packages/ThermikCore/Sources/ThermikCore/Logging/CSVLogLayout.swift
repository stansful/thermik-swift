// CSVLogLayout.swift — Thermik (MIT). The column layout of a Thermik CSV log and how one
// sample maps onto it (SPEC §2.12). Shared by the app's CSVLoggingService and `thermik-probe log write`, so both
// produce byte-identical layouts.
//
// Column order: timestamp, headline, fans (rpm/target per fan), power, usage, thermal, battery, sensors, then
// fan_mode and event (those two are flags on CSVLogHeader). Ids are stable machine names; the EN/RU names below are
// DATA for the `.columns.json` sidecar (both languages are always written), not UI strings.
import Foundation

/// One sample's values, keyed the way the layout needs them. nil anywhere → empty cell.
public struct CSVLogSample: Sendable {
    public struct Fan: Sendable, Equatable {
        public var actualRPM: Double?
        public var targetRPM: Double?
        public init(actualRPM: Double?, targetRPM: Double?) { self.actualRPM = actualRPM; self.targetRPM = targetRPM }
    }
    public var aggregates: AggregateValues
    public var fans: [Int: Fan]
    public var power: PowerValues
    public var cpuW: Double?
    public var gpuW: Double?
    public var cpuUsagePercent: Double?
    public var gpuUsagePercent: Double?
    public var memoryUsedGB: Double?
    public var pressure: ThermalPressure?
    public var batteryPercent: Int?
    public var onAC: Bool?
    public var sensors: [SensorID: Double]
    public init(aggregates: AggregateValues = .empty, fans: [Int: Fan] = [:], power: PowerValues = .empty, cpuW: Double? = nil,
                gpuW: Double? = nil, cpuUsagePercent: Double? = nil, gpuUsagePercent: Double? = nil, memoryUsedGB: Double? = nil,
                pressure: ThermalPressure? = nil, batteryPercent: Int? = nil, onAC: Bool? = nil, sensors: [SensorID: Double] = [:]) {
        self.aggregates = aggregates; self.fans = fans; self.power = power; self.cpuW = cpuW; self.gpuW = gpuW
        self.cpuUsagePercent = cpuUsagePercent; self.gpuUsagePercent = gpuUsagePercent; self.memoryUsedGB = memoryUsedGB
        self.pressure = pressure; self.batteryPercent = batteryPercent; self.onAC = onAC; self.sensors = sensors
    }
}

public enum CSVLogLayout {
    /// A sensor column: id "smc:Tp01" / "hid:PMU tdie1" with the DB names.
    public static func sensorColumn(_ s: Sensor) -> CSVColumn {
        CSVColumn(id: s.id.description, nameEN: s.descriptor.name, nameRU: s.descriptor.nameRu ?? s.descriptor.name)
    }

    /// Numeric columns for `include` (fan_mode / event are header flags, see `header(…)`).
    /// `fanIndices`: fans present (empty on fanless Macs). `sensors`: the chosen sensor columns (with `.sensors`).
    public static func columns(include: Set<LogColumnGroup>, fanIndices: [Int], sensors: [CSVColumn]) -> [CSVColumn] {
        var c: [CSVColumn] = []
        if include.contains(.headline) { c += headlineColumns() }
        if include.contains(.fans) { c += fanColumns(fanIndices) }
        if include.contains(.power) { c += powerColumns() }
        if include.contains(.usage) { c += usageColumns() }
        if include.contains(.thermal) { c += thermalColumns() }
        if include.contains(.battery) { c += batteryColumns() }
        if include.contains(.sensors) { c += sensors }
        return c
    }

    private static func headlineColumns() -> [CSVColumn] {
        [CSVColumn(id: "cpu_avg", nameEN: "CPU average (°C)", nameRU: "ЦП, среднее (°C)"),
         CSVColumn(id: "cpu_hottest", nameEN: "CPU hottest (°C)", nameRU: "ЦП, максимум (°C)"),
         CSVColumn(id: "gpu_avg", nameEN: "GPU average (°C)", nameRU: "ГП, среднее (°C)"),
         CSVColumn(id: "gpu_hottest", nameEN: "GPU hottest (°C)", nameRU: "ГП, максимум (°C)"),
         CSVColumn(id: "soc", nameEN: "SoC die (°C)", nameRU: "Кристалл SoC (°C)"),
         CSVColumn(id: "memory", nameEN: "Memory (°C)", nameRU: "Память (°C)"),
         CSVColumn(id: "ssd", nameEN: "SSD (°C)", nameRU: "SSD (°C)"),
         CSVColumn(id: "battery", nameEN: "Battery (°C)", nameRU: "Аккумулятор (°C)")]
    }

    private static func fanColumns(_ fanIndices: [Int]) -> [CSVColumn] {
        var columns: [CSVColumn] = []
        for i in fanIndices.sorted() {
            columns += [CSVColumn(id: "fan\(i)_rpm", nameEN: "Fan \(i + 1) speed (rpm)", nameRU: "Вентилятор \(i + 1), скорость (об/мин)"),
                        CSVColumn(id: "fan\(i)_target", nameEN: "Fan \(i + 1) target (rpm)", nameRU: "Вентилятор \(i + 1), цель (об/мин)")]
        }
        return columns
    }

    private static func powerColumns() -> [CSVColumn] {
        [CSVColumn(id: "system_w", nameEN: "System power (W)", nameRU: "Мощность системы (Вт)"),
         CSVColumn(id: "soc_w", nameEN: "SoC power (W)", nameRU: "Мощность SoC (Вт)"),
         CSVColumn(id: "battery_w", nameEN: "Battery power (W)", nameRU: "Мощность аккумулятора (Вт)"),
         CSVColumn(id: "cpu_w", nameEN: "CPU power (W)", nameRU: "Мощность ЦП (Вт)"),
         CSVColumn(id: "gpu_w", nameEN: "GPU power (W)", nameRU: "Мощность ГП (Вт)")]
    }

    private static func usageColumns() -> [CSVColumn] {
        [CSVColumn(id: "cpu_usage", nameEN: "CPU usage (%)", nameRU: "Загрузка ЦП (%)"),
         CSVColumn(id: "gpu_usage", nameEN: "GPU usage (%)", nameRU: "Загрузка ГП (%)"),
         CSVColumn(id: "mem_used_gb", nameEN: "Memory used (GB)", nameRU: "Использовано памяти (ГБ)")]
    }

    private static func thermalColumns() -> [CSVColumn] {
        [CSVColumn(id: "thermal_pressure", nameEN: "Thermal pressure (0 nominal … 4 sleeping)",
                   nameRU: "Тепловая нагрузка (0 норма … 4 сон)")]
    }

    private static func batteryColumns() -> [CSVColumn] {
        [CSVColumn(id: "battery_pct", nameEN: "Battery charge (%)", nameRU: "Заряд аккумулятора (%)"),
         CSVColumn(id: "on_ac", nameEN: "On AC power (1/0)", nameRU: "От сети (1/0)")]
    }

    public static func header(config: LogConfig, columns: [CSVColumn], hasFans: Bool, modelIdentifier: String, chip: String,
                              osVersion: String, appVersion: String) -> CSVLogHeader {
        CSVLogHeader(modelIdentifier: modelIdentifier, chip: chip, osVersion: osVersion, appVersion: appVersion,
                     intervalSeconds: config.intervalSeconds, numericColumns: columns,
                     includesFanMode: config.include.contains(.fans) && hasFans, includesEvents: config.include.contains(.events))
    }

    /// Values aligned with `columns`.
    public static func numbers(for columns: [CSVColumn], sample s: CSVLogSample) -> [Double?] {
        columns.map { value(id: $0.id, s) }
    }

    private static let aggregateKinds: [String: AggregateKind] = [
        "cpu_avg": .cpuAverage, "cpu_hottest": .cpuHottest, "gpu_avg": .gpuAverage, "gpu_hottest": .gpuHottest,
        "soc": .socDie, "memory": .memory, "ssd": .ssd, "battery": .battery,
    ]

    private static func value(id: String, _ s: CSVLogSample) -> Double? {
        if let kind = aggregateKinds[id] { return s.aggregates[kind] }
        switch id {
        case "system_w": return s.power.systemTotalW
        case "soc_w": return s.power.socW
        case "battery_w": return s.power.batteryW
        case "cpu_w": return s.cpuW
        case "gpu_w": return s.gpuW
        default: return miscValue(id: id, s)
        }
    }

    private static func miscValue(id: String, _ s: CSVLogSample) -> Double? {
        switch id {
        case "cpu_usage": return s.cpuUsagePercent
        case "gpu_usage": return s.gpuUsagePercent
        case "mem_used_gb": return s.memoryUsedGB
        case "thermal_pressure": return s.pressure.map { Double($0.rawValue) }
        case "battery_pct": return s.batteryPercent.map(Double.init)
        case "on_ac": return s.onAC.map { $0 ? 1 : 0 }
        default: return dynamicValue(id: id, s)
        }
    }

    private static func dynamicValue(id: String, _ s: CSVLogSample) -> Double? {
        if let sensor = SensorID(id), id.contains(":") { return s.sensors[sensor] }
        guard id.hasPrefix("fan"), let underscore = id.firstIndex(of: "_"),
              let index = Int(id[id.index(id.startIndex, offsetBy: 3)..<underscore]) else { return nil }
        let fan = s.fans[index]
        if id.hasSuffix("_rpm") { return fan?.actualRPM }
        if id.hasSuffix("_target") { return fan?.targetRPM }
        return nil
    }

    /// "system" | "curve:balanced" | "curve:custom" | "fixed:50" | "max" (CSVLogRow.fanMode).
    public static func fanModeToken(_ mode: FanMode, curve: FanCurve?, fixedPercent: Double?) -> String {
        switch mode {
        case .system: return "system"
        case .max: return "max"
        case .curve: return "curve:" + (curve?.presetID?.rawValue ?? "custom")
        case .fixed: return "fixed:" + (fixedPercent.map { CSVLogWriter.number($0, decimals: 0) } ?? "")
        }
    }
}
