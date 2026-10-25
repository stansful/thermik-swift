// SystemSampler.swift — Thermik (MIT). OWNER: Unit 2. STUB from Unit 0; API FROZEN:
// `public actor SystemSampler: SystemSampling` + `init()`.
import Foundation

public actor SystemSampler: SystemSampling {
    public init() {}
    public func start() async -> MachineInfo {
        MachineInfo(modelIdentifier: "Mac", marketingName: nil, boardID: nil, chip: "Unknown", isAppleSilicon: true,
                    isTranslated: false, osVersion: ProcessInfo.processInfo.operatingSystemVersionString, memoryBytes: 0,
                    logicalCPUs: ProcessInfo.processInfo.activeProcessorCount, perfLevels: [], cpuTopology: [],
                    gpuName: nil, gpuCores: nil)
    }
    public func sample(_ request: SystemSampleRequest) async -> SystemFrame {
        SystemFrame(date: Date(), cpuLoad: nil, memory: nil, gpu: nil, soc: nil, battery: nil, powerSources: nil,
                    pressure: .nominal, processThermalState: .nominal)
    }
    public func slowData(_ request: SlowDataRequest) async -> SlowSystemData { SlowSystemData() }
    public func powerLog(limit: Int) async -> [PowerLogEvent] { [] }
    public func topProcesses(limit: Int) async -> [ProcessCPU] { [] }
    public func didWake() async {}
}
