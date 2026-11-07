// DemoSamplers.swift — Thermik (MIT). Synthetic M4-Max-like samplers for `-ThermikDemo YES`.
import Foundation
import ThermikSMC

public actor DemoSensorSampler: SensorSampling {
    private var t0 = Date()
    private var inventory: SensorInventory?
    public init() {}

    public func start() async throws -> SensorInventory {
        let (sensors, headline) = Self.sensorCatalog()
        let inv = Self.inventory(sensors: sensors, headline: headline)
        inventory = inv
        t0 = Date()
        return inv
    }

    private static func sensorDatabase() -> ChipSensorDatabase? {
        guard let url = Bundle.module.url(forResource: "t6041", withExtension: "json", subdirectory: "SensorDB")
                ?? Bundle.module.url(forResource: "t6041", withExtension: "json") else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChipSensorDatabase.self, from: data)
    }

    private static func sensorCatalog() -> (sensors: [Sensor], headline: [HeadlineSet: [SensorID]]) {
        guard let db = sensorDatabase() else { return ([], [:]) }
        let sensors = db.sensors.filter { !$0.role.isNeverShown }.map {
            Sensor(id: SensorID(databaseKey: $0.key), quantity: .temperature, descriptor: $0, smcType: "flt ", isHeuristic: false)
        }
        let headline = Dictionary(uniqueKeysWithValues: HeadlineSet.allCases.map { set in
            (set, db.headlineKeys(set).map { SensorID(databaseKey: $0) })
        })
        return (sensors, headline)
    }

    private static func fanProfile() -> FanHardwareProfile {
        let fans = (0..<2).map { FanDescriptor(index: $0, name: $0 == 0 ? "Left Fan" : "Right Fan", minRPM: 1350, maxRPM: 5777,
                                              targetType: .flt, modeKey: .fan(FanHardwareProfile.modeUpper, $0)) }
        var profile = FanHardwareProfile(fans: fans, scheme: .appleSilicon(modeKeyTemplate: FanHardwareProfile.modeUpper, hasFtst: true))
        profile.hasFtstKey = true
        return profile
    }

    private static func inventory(sensors: [Sensor], headline: [HeadlineSet: [SensorID]]) -> SensorInventory {
        SensorInventory(
            identity: ChipIdentity(platformName: "t6041", targetType: "J616c", modelIdentifier: "Mac16,5", chipName: "Apple M4 Max",
                                   isAppleSilicon: true, smcPlatform: "j616c"),
            sensors: sensors, headline: headline,
            safetySet: (headline[.cpuHotspot] ?? []) + (headline[.gpu] ?? []),
            fanProfile: fanProfile(), catalogStatus: .verified(platform: "t6041"), smcAvailable: true, smcKeyCount: 3512,
            dieLayout: [], fanNames: ["Left", "Right"])
    }

    public func sample(_ request: SampleRequest) async -> SensorFrame {
        let now = Date()
        let t = now.timeIntervalSince(t0)
        let load = 0.5 + 0.5 * sin(t / 40)                        // slow synthetic load wave
        let values = sensorValues(request.sensorIDs, load: load, t: t)
        let fans = fanState(load: load, now: now)
        return SensorFrame(date: now, values: values, raw: values, gated: [], fans: request.components.contains(.fans) ? fans : nil,
                           power: PowerValues(systemTotalW: 20 + 90 * load, dcInW: 22 + 90 * load, batteryW: 0, socW: 12 + 70 * load),
                           isPostWake: false)
    }

    private func sensorValues(_ ids: [SensorID], load: Double, t: TimeInterval) -> [SensorID: Double] {
        var values: [SensorID: Double] = [:]
        for id in ids {
            guard let sensor = inventory?.sensors.first(where: { $0.id == id }) else { continue }
            let base = baseTemperature(for: sensor.descriptor.group, load: load)
            let jitter = sin(Double(abs(id.key.hashValue % 97)) + t / 3) * 0.8
            values[id] = base + jitter + (sensor.role == .hotspot || sensor.role == .maximum ? 8 : 0)
        }
        return values
    }

    private func baseTemperature(for group: SensorGroup, load: Double) -> Double {
        switch group {
        case .cpuPerformance, .cpuAggregate, .cpuFabric: return 58 + 30 * load
        case .cpuEfficiency: return 56 + 18 * load
        case .gpu, .gpuAggregate, .socFabric, .soc: return 52 + 20 * load
        case .memory: return 46 + 10 * load
        default: return peripheralBaseTemperature(for: group, load: load)
        }
    }

    private func peripheralBaseTemperature(for group: SensorGroup, load: Double) -> Double {
        switch group {
        case .battery: return 33 + 1.5 * load
        case .storage: return 33 + 6 * load
        case .enclosure: return 31 + 2 * load
        case .airflow: return 45 + 4 * load
        case .ports: return 36 + 4 * load
        default: return 48 + 8 * load
        }
    }

    private func fanState(load: Double, now: Date) -> FanControlState {
        let rpm = 1350 + (5777 - 1350) * max(0, load - 0.4)
        return FanControlState(ftst: 0, forceBits: nil, fans: (0..<2).map {
            FanSnapshot(index: $0, actualRPM: rpm + Double($0) * 40, targetRPM: rpm, mode: .auto, dutyCycle: rpm / 9600, timestamp: now)
        })
    }

    public func willSleep() async {}
    public func didWake() async {}
}

public actor DemoSystemSampler: SystemSampling {
    public init() {}
    public func start() async -> MachineInfo {
        MachineInfo(modelIdentifier: "Mac16,5", marketingName: "MacBook Pro (16-inch, Nov 2024)", boardID: "J616cAP",
                    chip: "Apple M4 Max", isAppleSilicon: true, isTranslated: false, osVersion: "27.0.1 (26A434)",
                    memoryBytes: 48 << 30, logicalCPUs: 16,
                    perfLevels: [PerfLevel(name: "Performance", logicalCPUs: 12, physicalCPUs: 12, l2CacheBytes: 16 << 20),
                                 PerfLevel(name: "Efficiency", logicalCPUs: 4, physicalCPUs: 4, l2CacheBytes: 4 << 20)],
                    cpuTopology: (0..<16).map { CPUCoreInfo(id: $0, type: $0 < 4 ? "E" : "P", cluster: $0 < 4 ? 0 : ($0 < 10 ? 1 : 2)) },
                    gpuName: "Apple M4 Max", gpuCores: 40)
    }

    public func sample(_ request: SystemSampleRequest) async -> SystemFrame {
        let battery = Self.demoBattery()
        return SystemFrame(date: Date(),
                           cpuLoad: request.contains(.cpuLoad) ? (0..<16).map { i in CoreLoad(user: i < 4 ? 0.4 : 0.1, system: 0.05, nice: 0, idle: i < 4 ? 0.55 : 0.85) } : nil,
                           memory: nil, gpu: GPUUtilization(model: "Apple M4 Max", coreCount: 40, devicePercent: 12, rendererPercent: 10, tilerPercent: 3, inUseSystemMemory: nil),
                           soc: nil, battery: request.contains(.battery) ? battery : nil,
                           powerSources: PowerSourceSummary(kind: .ac, timeRemaining: .infinity, batteryWarningLevel: 1, lowPowerMode: false),
                           pressure: .nominal, processThermalState: .nominal)
    }

    private static func demoBattery() -> BatterySnapshot {
        BatterySnapshot(cycleCount: 34, designCycleCount: 1000, designCapacity_mAh: 8579, rawMaxCapacity_mAh: 8289,
                        nominalChargeCapacity_mAh: 8533, rawCurrentCapacity_mAh: 6540, chargePercent: 81,
                        temperatureC: 33.4, voltage_mV: 12340, amperage_mA: 0, isCharging: false,
                        externalConnected: true, fullyCharged: false, minutesToEmpty: nil, minutesToFull: nil,
                        permanentFailureStatus: 0, notChargingReason: 0x1000000, cellVoltages_mV: [4112, 4113, 4115],
                        adapter: PowerAdapterInfo(name: "140W USB-C Power Adapter", watts: 140, voltage_mV: 28000,
                                                  current_mA: 4990, isWireless: false),
                        systemPowerIn_mW: 35000, systemLoad_mW: 35000, batteryPower_mW: 0)
    }

    public func slowData(_ request: SlowDataRequest) async -> SlowSystemData {
        SlowSystemData(appleBatteryHealth: AppleBatteryHealth(maximumCapacityPercent: 100, conditionRaw: "Good", condition: .normal),
                       nvme: [], boot: nil, shutdownVerdict: .normalRestart)
    }
    public func powerLog(limit: Int) async -> [PowerLogEvent] { [] }
    public func topProcesses(limit: Int) async -> [ProcessCPU] { [] }
    public func didWake() async {}
}
