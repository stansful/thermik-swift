// SystemStore.swift — Thermik (MIT). Minimal implementation by Unit 0; OWNER afterwards: Unit 5. Surface FROZEN.
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
        guard let s = tick.system else { return }
        if let l = s.cpuLoad {
            if l != cpuLoad { cpuLoad = l }
            let total = s.cpuTotalPercent
            if total != cpuTotalPercent { cpuTotalPercent = total }
        }
        if let m = s.memory, m != memory { memory = m }
        if let g = s.gpu, g != gpu { gpu = g }
        // nil too: off the System page IOReport is not read, and its last numbers must not reappear on the next visit.
        if s.soc != soc { soc = s.soc }
        if let b = s.battery, b != battery { battery = b }
        if let p = s.powerSources, p != powerSource {
            let old = powerSource?.kind
            powerSource = p
            if let old, old != p.kind { events?.record(.powerSourceChanged(p.kind), date: tick.date) }
        }
        updatePressure(s.pressure, at: tick.date)
        if s.processThermalState != processThermalState { processThermalState = s.processThermalState }
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
