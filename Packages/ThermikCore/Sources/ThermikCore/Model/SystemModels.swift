// SystemModels.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). Data snapshots produced by Unit 2's readers.
// Field sets copied from research/system/prod/*.swift (verified on M4 Max / macOS 27.0.1).
// Readers (Unit 2) live in ThermikCore/System/*.swift and construct these with the memberwise inits.
import Foundation

// MARK: Battery & power sources (SYS §2)

public struct PowerAdapterInfo: Sendable, Equatable {
    public var name: String?               // "140W USB-C Power Adapter"
    public var watts: Int?
    public var voltage_mV: Int?
    public var current_mA: Int?
    public var isWireless: Bool
}

/// One read of AppleSmartBattery (pack BatteryData → root → root BatteryData lookup order on macOS 26/27).
public struct BatterySnapshot: Sendable, Equatable {
    public var cycleCount: Int?
    public var designCycleCount: Int?              // DesignCycleCount9C (1000); IOPS' 300 is legacy
    public var designCapacity_mAh: Int?
    public var rawMaxCapacity_mAh: Int?            // AppleRawMaxCapacity (noisy ±3 %)
    public var nominalChargeCapacity_mAh: Int?     // NominalChargeCapacity (tracks Apple's "Maximum Capacity")
    public var rawCurrentCapacity_mAh: Int?
    public var chargePercent: Int?                 // CurrentCapacity (UI %)
    public var temperatureC: Double?               // Temperature / 100
    public var voltage_mV: Int?
    public var amperage_mA: Int?                   // signed; < 0 = discharging
    public var isCharging: Bool
    public var externalConnected: Bool
    public var fullyCharged: Bool
    public var minutesToEmpty: Int?                // nil while calculating (65535)
    public var minutesToFull: Int?
    public var permanentFailureStatus: Int?        // 0 = OK, ≠ 0 = service battery
    public var notChargingReason: Int?             // opaque bitfield
    public var cellVoltages_mV: [Int]
    public var adapter: PowerAdapterInfo?
    public var systemPowerIn_mW: Int?              // PowerTelemetryData.SystemPowerIn
    public var systemLoad_mW: Int?                 // PowerTelemetryData.SystemLoad (whole-Mac power)
    public var batteryPower_mW: Int?

    public var healthPercent: Double? { ratio(nominalChargeCapacity_mAh, designCapacity_mAh) }
    public var rawHealthPercent: Double? { ratio(rawMaxCapacity_mAh, designCapacity_mAh) }
    public var batteryPowerW: Double? {
        guard let v = voltage_mV, let a = amperage_mA else { return nil }
        return Double(v) * Double(a) / 1_000_000
    }
    private func ratio(_ a: Int?, _ b: Int?) -> Double? {
        guard let a, let b, b > 0 else { return nil }
        return Double(a) / Double(b) * 100
    }
}

/// `system_profiler SPPowerDataType -json` (launch + every 6 h): Apple's own figures (not localized in JSON).
public struct AppleBatteryHealth: Sendable, Equatable {
    public var maximumCapacityPercent: Int?        // "100 %" → 100
    public var conditionRaw: String?               // "Good", "Service Recommended", …
    public var condition: BatteryCondition
}

public enum BatteryCondition: String, Sendable, Equatable, Codable { case normal, serviceRecommended, permanentFailure, unknown }

public struct PowerSourceSummary: Sendable, Equatable {
    public var kind: PowerSourceKind
    /// Seconds; nil = unknown/calculating; .infinity = on AC (kIOPSTimeRemainingUnlimited).
    public var timeRemaining: TimeInterval?
    public var batteryWarningLevel: Int            // 1 none, 2 early, 3 final
    public var lowPowerMode: Bool
}

// MARK: Load (SYS §3)

public struct CoreLoad: Sendable, Equatable {
    public var user: Double, system: Double, nice: Double, idle: Double      // fractions 0…1
    public var total: Double { user + system + nice }
}

public enum MemoryPressure: Int, Sendable, Equatable { case normal = 1, warning = 2, critical = 4, unknown = 0 }

public struct MemorySnapshot: Sendable, Equatable {
    public var total: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var freePercentLevel: Int?
    public var pressure: MemoryPressure
    public var used: UInt64 { app + wired + compressed }
}

public struct GPUUtilization: Sendable, Equatable {
    public var model: String?
    public var coreCount: Int?
    public var devicePercent: Int?                 // "Device Utilization %" (Activity Monitor's GPU)
    public var rendererPercent: Int?
    public var tilerPercent: Int?
    public var inUseSystemMemory: UInt64?
}

// MARK: IOReport (SYS §4)

public struct DomainFrequency: Sendable, Equatable {
    public var name: String                        // "ECPU", "PCPU", "PCPU1", "GPUPH", "ECPU000"…
    public var mhz: Double                         // residency-weighted, REQUESTED DVFS state ("≈")
    public var activePercent: Double
}

public struct SoCPower: Sendable, Equatable {
    public enum Source: String, Sendable { case energyModel, clpc, pmpHistogram, unavailable }
    public var cpuW: Double?, gpuW: Double?, aneW: Double?, dramW: Double?
    public var source: Source
}

public struct SoCMetrics: Sendable, Equatable {
    public var interval: TimeInterval
    public var clusters: [DomainFrequency]
    public var cores: [DomainFrequency]
    public var gpu: DomainFrequency?
    public var power: SoCPower
    public var ssdControllerTempC: Double?         // ANS2 › MSPn › Temperature(0), raw sample
}

// MARK: Thermal (SYS §5)

/// macOS OSThermalPressureLevel (notify key com.apple.system.thermalpressurelevel). iOS uses 0/10/20… — never mix.
public enum ThermalPressure: UInt64, Sendable, CaseIterable, Codable, Comparable {
    case nominal = 0, moderate = 1, heavy = 2, trapping = 3, sleeping = 4
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// ProcessInfo.thermalState mirrored as our own Sendable enum.
public enum ProcessThermalState: Int, Sendable, Codable { case nominal = 0, fair, serious, critical }

// MARK: Storage (SYS §6)

public struct NVMeHealth: Sendable, Equatable {
    public var bsdName: String?
    public var model: String?
    public var firmware: String?
    public var temperatureC: Int
    public var criticalWarning: UInt8
    public var availableSparePercent: Int
    public var availableSpareThresholdPercent: Int
    public var percentageUsed: Int
    public var dataReadBytes: Double
    public var dataWrittenBytes: Double
    public var powerCycles: UInt64
    public var powerOnHours: UInt64
    public var unsafeShutdowns: UInt64
    public var mediaErrors: UInt64
    public var errorLogEntries: UInt64
}

// MARK: Boot / shutdown / power log (SYS §7)

public struct BootHistory: Sendable, Equatable {
    public var bootTime: Date?
    public var lastSleepTime: Date?
    public var lastWakeTime: Date?
    public var bootSessionUUID: String?
    public var shutdownReason: String?             // kern.shutdownreason (Apple Silicon; raw tokens)
    public var bootReason: String?                 // kern.bootreason
    public var wakeReason: String?                 // kern.wakereason / IOPMrootDomain "Wake Reason"
    public var lastSleepReason: String?            // IOPMrootDomain "Last Sleep Reason"
    public var wakeType: String?
    public var lidClosed: Bool?
    public var panicLogPath: String?               // non-empty → this boot followed a kernel panic
    public var intelShutdownCause: Int?            // "Previous shutdown cause: N" (Intel/T2 only)
}

/// Heuristic, conservative classification (SYS §7.1). Always show the raw string too.
public enum ShutdownVerdict: Sendable, Equatable, Codable {
    case normalRestart, normalShutdown, forced, thermal, powerLoss, watchdog, kernelPanic
    case intelCode(Int)
    case other
    case unknown
    public var isAbnormal: Bool {
        switch self {
        case .normalRestart, .normalShutdown, .unknown, .other: return false
        case .forced, .thermal, .powerLoss, .watchdog, .kernelPanic: return true
        case .intelCode(let c): return !(c == 5 || c == 1 || c == 3)
        }
    }
}

public struct PowerLogEvent: Sendable, Equatable {
    public var date: Date
    public var kind: String                        // "Sleep", "Wake", "DarkWake", "Start", "ThermalEvent", "BatteryHealth", …
    public var message: String
}

// MARK: Machine (SYS §8)

public struct PerfLevel: Sendable, Equatable {
    public var name: String
    public var logicalCPUs: Int
    public var physicalCPUs: Int
    public var l2CacheBytes: Int?
}

public struct CPUCoreInfo: Sendable, Equatable { public var id: Int; public var type: String; public var cluster: Int }

public struct MachineInfo: Sendable, Equatable {
    public var modelIdentifier: String             // "Mac16,5"
    public var marketingName: String?              // "MacBook Pro (16-inch, Nov 2024)"
    public var boardID: String?                    // "J616cAP"
    public var chip: String                        // "Apple M4 Max"
    public var isAppleSilicon: Bool
    public var isTranslated: Bool
    public var osVersion: String                   // "27.0.1 (26A434)"
    public var memoryBytes: UInt64
    public var logicalCPUs: Int
    public var perfLevels: [PerfLevel]             // index 0 = fastest tier
    public var cpuTopology: [CPUCoreInfo]
    public var gpuName: String?
    public var gpuCores: Int?
}

// MARK: Top processes (P1, notifications)

public struct ProcessCPU: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var cpuPercent: Double                  // of one core
}
