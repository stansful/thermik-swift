// SamplingProtocols.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). Sampler actors ↔ app runtime.
import Foundation
import ThermikSMC

/// What to read in one sensor tick (built by the app's SamplingCoordinator from what is visible/needed).
public struct SampleRequest: Sendable, Equatable {
    public var sensorIDs: [SensorID]          // SMC + HID mixed; HID ids are read at most every hidInterval
    public var includeFans: Bool
    public var includePower: Bool
    public init(sensorIDs: [SensorID], includeFans: Bool = true, includePower: Bool = true) {
        self.sensorIDs = sensorIDs; self.includeFans = includeFans; self.includePower = includePower
    }
}

/// Result of discovery (once at start, again after wake if the SMC was reopened).
public struct SensorInventory: Sendable {
    public var identity: ChipIdentity
    /// Every temperature sensor (visible + hidden, never `isNeverShown` roles), DB order then heuristic keys.
    public var sensors: [Sensor]
    public var headline: [HeadlineSet: [SensorID]]
    /// Die sensors used for safetyTop4 / rawHottestDie (default headline.cpuHotspot ∪ headline.gpu).
    public var safetySet: [SensorID]
    public var fanProfile: FanHardwareProfile
    public var catalogStatus: CatalogStatus
    public var smcAvailable: Bool
    public var smcKeyCount: Int
    public var dieLayout: [DieLayoutPoint]
    public var fanNames: [String]?            // from DB (English) — UI localizes Left/Right itself
    public init(identity: ChipIdentity, sensors: [Sensor], headline: [HeadlineSet: [SensorID]], safetySet: [SensorID],
                fanProfile: FanHardwareProfile, catalogStatus: CatalogStatus, smcAvailable: Bool, smcKeyCount: Int,
                dieLayout: [DieLayoutPoint], fanNames: [String]?) {
        self.identity = identity; self.sensors = sensors; self.headline = headline; self.safetySet = safetySet
        self.fanProfile = fanProfile; self.catalogStatus = catalogStatus; self.smcAvailable = smcAvailable
        self.smcKeyCount = smcKeyCount; self.dieLayout = dieLayout; self.fanNames = fanNames
    }
}

/// One sensor tick. Values are RAW decoded and SANITIZED (invalid ones omitted from `values`); no smoothing.
public struct SensorFrame: Sendable {
    public var date: Date
    public var values: [SensorID: Double]     // valid values only (°C)
    public var raw: [SensorID: Double]        // decoded before the sanity filter (inspector / diagnostics)
    public var gated: Set<SensorID>           // invalid because the P-cluster is power-gated (all its probes invalid)
    public var fans: FanControlState?
    public var power: PowerValues
    public var isPostWake: Bool               // within 3 s after wake (P-core values forced invalid)
    public init(date: Date, values: [SensorID: Double], raw: [SensorID: Double], gated: Set<SensorID>,
                fans: FanControlState?, power: PowerValues, isPostWake: Bool) {
        self.date = date; self.values = values; self.raw = raw; self.gated = gated
        self.fans = fans; self.power = power; self.isPostWake = isPostWake
    }
    public static func empty(_ date: Date = Date()) -> SensorFrame {
        SensorFrame(date: date, values: [:], raw: [:], gated: [], fans: nil, power: .empty, isPostWake: false)
    }
}

public protocol SensorSampling: Actor {
    /// Opens the SMC, enumerates keys, loads the catalog, discovers HID and fans. Throws if SMC is unavailable
    /// AND HID is unavailable (app then shows "Sensors unavailable").
    func start() async throws -> SensorInventory
    /// One read pass. Never throws: single-key failures are omitted; a lost connection is reopened internally.
    func sample(_ request: SampleRequest) async -> SensorFrame
    func willSleep() async
    /// Reopen SMC if needed, refresh HID services, mark the next 3 s as post-wake.
    func didWake() async
}

public struct SystemSampleRequest: Sendable, Equatable {
    public var cpuLoad = false
    public var memory = false
    public var gpuUsage = false
    public var soc = false                    // IOReport frequencies/power (~6–8 ms): only while visible
    public var battery = false
    public var powerSources = false
    public init(cpuLoad: Bool = false, memory: Bool = false, gpuUsage: Bool = false, soc: Bool = false,
                battery: Bool = false, powerSources: Bool = false) {
        self.cpuLoad = cpuLoad; self.memory = memory; self.gpuUsage = gpuUsage; self.soc = soc
        self.battery = battery; self.powerSources = powerSources
    }
}

public struct SystemFrame: Sendable {
    public var date: Date
    public var cpuLoad: [CoreLoad]?           // per logical CPU, index = logical id (0..<E are E-cores on AS)
    public var memory: MemorySnapshot?
    public var gpu: GPUUtilization?
    public var soc: SoCMetrics?
    public var battery: BatterySnapshot?
    public var powerSources: PowerSourceSummary?
    public var pressure: ThermalPressure
    public var processThermalState: ProcessThermalState
    public init(date: Date, cpuLoad: [CoreLoad]?, memory: MemorySnapshot?, gpu: GPUUtilization?, soc: SoCMetrics?,
                battery: BatterySnapshot?, powerSources: PowerSourceSummary?, pressure: ThermalPressure,
                processThermalState: ProcessThermalState) {
        self.date = date; self.cpuLoad = cpuLoad; self.memory = memory; self.gpu = gpu; self.soc = soc
        self.battery = battery; self.powerSources = powerSources; self.pressure = pressure
        self.processThermalState = processThermalState
    }
    public var cpuTotalPercent: Double? {
        guard let l = cpuLoad, !l.isEmpty else { return nil }
        return l.map(\.total).reduce(0, +) / Double(l.count) * 100
    }
}

public struct SlowDataRequest: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let appleBatteryHealth = SlowDataRequest(rawValue: 1)   // system_profiler (125 ms): launch + 6 h
    public static let nvme = SlowDataRequest(rawValue: 2)                 // SMART (4 ms): every 60 s
    public static let boot = SlowDataRequest(rawValue: 4)                 // sysctl + IOPMrootDomain: launch + wake
    public static let all: SlowDataRequest = [.appleBatteryHealth, .nvme, .boot]
}

public struct SlowSystemData: Sendable {
    public var appleBatteryHealth: AppleBatteryHealth?
    public var nvme: [NVMeHealth]?
    public var boot: BootHistory?
    public var shutdownVerdict: ShutdownVerdict?
    public init(appleBatteryHealth: AppleBatteryHealth? = nil, nvme: [NVMeHealth]? = nil, boot: BootHistory? = nil,
                shutdownVerdict: ShutdownVerdict? = nil) {
        self.appleBatteryHealth = appleBatteryHealth; self.nvme = nvme; self.boot = boot; self.shutdownVerdict = shutdownVerdict
    }
}

public protocol SystemSampling: Actor {
    func start() async -> MachineInfo
    func sample(_ request: SystemSampleRequest) async -> SystemFrame
    func slowData(_ request: SlowDataRequest) async -> SlowSystemData
    /// `pmset -g log` (1.4–3.4 s): on demand only (Diagnostics page).
    func powerLog(limit: Int) async -> [PowerLogEvent]
    /// P1: top CPU processes by delta since the previous call (libproc).
    func topProcesses(limit: Int) async -> [ProcessCPU]
    func didWake() async
}
