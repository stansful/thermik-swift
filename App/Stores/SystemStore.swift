// SystemStore.swift — Thermik (MIT).
// Readers run at their own cadences (SPEC §2.3.4), so a frame carries only what was read this tick: every field
// keeps its last value until the next read. Thermal pressure and the power source kind are logged as events.
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

    @ObservationIgnored private weak var events: EventLogStore?
    @ObservationIgnored private var pressureDay: Date?
    @ObservationIgnored private var hasPressureReading = false

    var hasBattery: Bool { battery != nil }
    var powerSourceKind: PowerSourceKind { powerSource?.kind ?? (battery?.externalConnected == false ? .battery : .ac) }

    /// Wired by AppEnvironment: pressure and power-source changes go to the event log (Logs page, CSV event column).
    func attach(events: EventLogStore) { self.events = events }

    func setMachine(_ m: MachineInfo) { machine = m }

    func apply(slow: SlowSystemData) {
        if let h = slow.appleBatteryHealth, h != appleBatteryHealth { appleBatteryHealth = h }
        if let n = slow.nvme, n != nvme { nvme = n }
        if let b = slow.boot, b != boot { boot = b }
        if let v = slow.shutdownVerdict, v != shutdownVerdict { shutdownVerdict = v }
    }

    func consume(_ tick: Tick) {
        guard let frame = tick.system else { return }
        updateCPU(frame)
        if let memory = frame.memory, memory != self.memory { self.memory = memory }
        if let gpu = frame.gpu, gpu != self.gpu { self.gpu = gpu }
        // nil too: off the System page IOReport is not read, and its last numbers must not reappear on the next visit.
        if frame.soc != soc { soc = frame.soc }
        if let battery = frame.battery, battery != self.battery { self.battery = battery }
        updatePowerSource(frame, at: tick.date)
        updatePressure(frame.pressure, at: tick.date)
        if frame.processThermalState != processThermalState { processThermalState = frame.processThermalState }
    }

    private func updateCPU(_ frame: SystemFrame) {
        guard let load = frame.cpuLoad else { return }
        if load != cpuLoad { cpuLoad = load }
        let total = frame.cpuTotalPercent
        if total != cpuTotalPercent { cpuTotalPercent = total }
    }

    private func updatePowerSource(_ frame: SystemFrame, at date: Date) {
        guard let source = frame.powerSources, source != powerSource else { return }
        let old = powerSource?.kind
        powerSource = source
        if let old, old != source.kind { events?.record(.powerSourceChanged(source.kind), date: date) }
    }

    private func updatePressure(_ p: ThermalPressure, at date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        if day != pressureDay {
            pressureDay = day
            if pressureEventsToday != 0 { pressureEventsToday = 0 }
        }
        if p >= .moderate && pressure < .moderate { pressureEventsToday += 1 }
        // The first reading is the starting state, not a change.
        if hasPressureReading, p != pressure { events?.record(.thermalPressureChanged(p), date: date) }
        hasPressureReading = true
        if p != pressure { pressure = p }
    }
}
