// SystemStore.swift — Thermik (MIT). Minimal implementation by Unit 0; OWNER afterwards: Unit 5. Surface FROZEN.
import Foundation
import Observation
import ThermikCore

@MainActor @Observable final class SystemStore: TickConsumer {
    private(set) var machine: MachineInfo?
    private(set) var battery: BatterySnapshot?
    private(set) var appleBatteryHealth: AppleBatteryHealth?
    private(set) var powerSource: PowerSourceSummary?
    private(set) var cpuLoad: [CoreLoad] = []
    private(set) var cpuTotalPercent: Double?
    private(set) var memory: MemorySnapshot?
    private(set) var gpu: GPUUtilization?
    private(set) var soc: SoCMetrics?
    private(set) var pressure: ThermalPressure = .nominal
    private(set) var processThermalState: ProcessThermalState = .nominal
    private(set) var nvme: [NVMeHealth] = []
    private(set) var boot: BootHistory?
    private(set) var shutdownVerdict: ShutdownVerdict?
    /// Number of transitions to ≥ moderate since local midnight (Diagnostics).
    private(set) var pressureEventsToday = 0

    var hasBattery: Bool { battery != nil }
    var powerSourceKind: PowerSourceKind { powerSource?.kind ?? (battery?.externalConnected == false ? .battery : .ac) }

    func setMachine(_ m: MachineInfo) { machine = m }

    func apply(slow: SlowSystemData) {
        if let h = slow.appleBatteryHealth { appleBatteryHealth = h }
        if let n = slow.nvme { nvme = n }
        if let b = slow.boot { boot = b }
        if let v = slow.shutdownVerdict { shutdownVerdict = v }
    }

    func consume(_ tick: Tick) {
        guard let s = tick.system else { return }
        if let l = s.cpuLoad { cpuLoad = l; cpuTotalPercent = s.cpuTotalPercent }
        if let m = s.memory { memory = m }
        if let g = s.gpu { gpu = g }
        if let x = s.soc { soc = x }
        if let b = s.battery { battery = b }
        if let p = s.powerSources { powerSource = p }
        if s.pressure > .nominal && pressure == .nominal { pressureEventsToday += 1 }
        pressure = s.pressure
        processThermalState = s.processThermalState
    }
}
