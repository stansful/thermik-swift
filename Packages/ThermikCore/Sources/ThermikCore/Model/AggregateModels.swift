// AggregateModels.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). Headline numbers & temperature inputs.
import Foundation

/// Computed headline values (definitions: SPEC §2.5.4). All °C.
public enum AggregateKind: String, Codable, Sendable, CaseIterable {
    case cpuAverage      // mean of valid headline.cpu (calibrated P+E) — the default menu-bar value
    case cpuHottest      // max of valid headline.cpuHotspot (Tpx1, Tpx9, Te06, Te0T on M4 Max)
    case gpuAverage      // mean of valid headline.gpu
    case gpuHottest      // max of valid headline.gpu
    case socHottest      // max(cpuAverage, gpuAverage) — default curve input for Balanced/Cool
    case socDie          // headline.soc (TCMb die average)
    case highestAll      // max over every visible, valid temperature sensor (TG "Highest")
    case averageAll      // mean over every visible, valid temperature sensor (TG "Computer average")
    case memory          // headline.memory
    case ssd             // headline.ssd
    case battery         // headline.battery
    case safetyTop4      // mean of the 4 hottest valid sensors of the safety set (engine critical input)
    case rawHottestDie   // max of the safety set (engine raw-critical input)
}

public struct AggregateValues: Sendable, Equatable {
    public var values: [AggregateKind: Double]
    /// Which sensor produced a maximum (for "Hottest · P-cluster 1 core max").
    public var sources: [AggregateKind: SensorID]
    public init(values: [AggregateKind: Double] = [:], sources: [AggregateKind: SensorID] = [:]) {
        self.values = values; self.sources = sources
    }
    public subscript(_ k: AggregateKind) -> Double? { values[k] }
    public static let empty = AggregateValues()
}

public struct GroupStat: Sendable, Equatable {
    public var mean: Double?
    public var max: Double?
    public var hottest: SensorID?
    public var valid: Int
    public var total: Int
    public init(mean: Double?, max: Double?, hottest: SensorID?, valid: Int, total: Int) {
        self.mean = mean; self.max = max; self.hottest = hottest; self.valid = valid; self.total = total
    }
}

/// SMC power keys (W). Apple Silicon: PSTR system total, PDTR DC-in, PPBR battery, PHPC SoC heat estimate.
public struct PowerValues: Sendable, Equatable, Codable {
    public var systemTotalW: Double?
    public var dcInW: Double?
    public var batteryW: Double?
    public var socW: Double?
    public init(systemTotalW: Double? = nil, dcInW: Double? = nil, batteryW: Double? = nil, socW: Double? = nil) {
        self.systemTotalW = systemTotalW; self.dcInW = dcInW; self.batteryW = batteryW; self.socW = socW
    }
    public static let empty = PowerValues()
}

/// Any temperature the fan engine, alerts or the menu bar can use as an input.
public enum TemperatureSource: Codable, Sendable, Hashable {
    case aggregate(AggregateKind)
    case sensor(SensorID)
}
