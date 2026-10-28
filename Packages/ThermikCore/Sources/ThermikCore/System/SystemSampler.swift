// SystemSampler.swift — Thermik (MIT). OWNER: Unit 2. API FROZEN: `public actor SystemSampler: SystemSampling` + `init()`.
// Owns every stateful System reader (SPEC §2.3.1, §2.7) and publishes Sendable snapshots. Never touches the SMC.
// Slow tools (`system_profiler`, `pmset`, `log show`) run through `ProcessRunner` on a utility GCD thread, so the actor is
// suspended (not blocked) while they run and `sample(_:)` keeps being served.
import Foundation
import os

public actor SystemSampler: SystemSampling {
    private static let log = Logger(subsystem: "app.thermik.Thermik", category: "system")
    /// `system_profiler SPPowerDataType` cadence (SPEC §2.3.4: launch + every 6 h); a failed run is retried after 10 min.
    private static let appleHealthTTL: Duration = .seconds(6 * 3600)
    private static let appleHealthRetry: Duration = .seconds(600)

    private let battery = BatteryReader()
    private let cpu = CPULoadSampler()
    private let thermal = ThermalPressureReader()
    private let top = TopProcessSampler()
    private var soc: SoCSampler?
    private var socUnavailable = false
    private var socSetupMilliseconds: Double?
    private var isAppleSilicon = (SysctlReader.int("hw.optional.arm64") ?? 0) == 1

    private var appleHealth: (value: AppleBatteryHealth?, at: ContinuousClock.Instant)?
    private var appleHealthTask: Task<AppleBatteryHealth?, Never>?
    private var intelCauseQueryRunning = false

    public init() {}

    // MARK: SystemSampling

    /// Machine identity (~1.5–5 ms) + primes the CPU-tick baseline so the first tick already has per-core load.
    public func start() async -> MachineInfo {
        let info = MachineInfoReader.read()
        isAppleSilicon = info.isAppleSilicon
        _ = cpu.sample()
        Self.log.info("machine \(info.modelIdentifier, privacy: .public), \(info.logicalCPUs, privacy: .public) CPUs, GPU cores \(info.gpuCores ?? 0, privacy: .public)")
        return info
    }

    /// One pass over the requested readers. Without `soc` ≈ 1–2 ms (battery ≈ 0.4, power sources ≈ 0.4, the rest
    /// ≈ 0.1–0.3 each); `soc` adds ≈ 4–6 ms (IOReport, dominated by the PMGR driver), and its first use creates the
    /// subscription (≈ 65 ms, logged). Thermal pressure is read on every call (~26 µs).
    public func sample(_ request: SystemSampleRequest) async -> SystemFrame {
        var load: [CoreLoad]?
        if request.cpuLoad {
            let l = cpu.sample()
            load = l.isEmpty ? nil : l                           // nil right after start/wake (no baseline yet)
        }
        let memory = request.memory ? MemoryReader.read() : nil
        let gpu = request.gpuUsage ? GPUReader.primary() : nil
        let socMetrics = request.soc ? sampleSoC() : nil
        let bat = request.battery ? battery.read() : nil
        let power = request.powerSources ? PowerSources.summary() : nil
        return SystemFrame(date: Date(), cpuLoad: load, memory: memory, gpu: gpu, soc: socMetrics, battery: bat,
                           powerSources: power, pressure: thermal.current(),
                           processThermalState: ThermalPressureReader.processThermalState())
    }

    public func slowData(_ request: SlowDataRequest) async -> SlowSystemData {
        var out = SlowSystemData()
        if request.contains(.boot) {
            let boot = bootHistory()
            out.boot = boot
            out.shutdownVerdict = ShutdownClassifier.classify(boot)
        }
        if request.contains(.nvme) { out.nvme = NVMeSMARTReader.readAll() }       // ~4 ms
        if request.contains(.appleBatteryHealth) { out.appleBatteryHealth = await appleBatteryHealth() }
        return out
    }

    /// `pmset -g log` (1.4–3.4 s): the newest `limit` interesting events, oldest first.
    public func powerLog(limit: Int) async -> [PowerLogEvent] {
        await PMSetLog.events(limit: limit)
    }

    /// Busiest processes (% of one core) since the previous call. When there is no recent baseline (first call, or
    /// more than 30 s ago) a fresh one is taken and the window is at least 0.5 s, so the answer reflects "right now".
    public func topProcesses(limit: Int) async -> [ProcessCPU] {
        if top.baselineAge.map({ $0 > 30 }) ?? true { _ = top.sample(limit: 0) }
        if let age = top.baselineAge, age < 0.5 { try? await Task.sleep(for: .seconds(0.5 - age)) }
        return top.sample(limit: limit)
    }

    /// Drops the CPU-tick, IOReport and process baselines: the first delta after wake would span the whole sleep.
    public func didWake() async {
        cpu.reset()
        soc?.reset()
        top.reset()
    }

    // MARK: Additive API (not part of the frozen protocol)

    /// P2 "Devices" section: Bluetooth accessory batteries (names deliberately not exposed). ~1 ms.
    public func accessories() async -> [AccessoryBattery] { PowerSources.accessories() }

    /// Wall time of the lazy IOReport setup (nil until the first `soc` request). Diagnostics / probe.
    public func socSetupTime() async -> Double? { socSetupMilliseconds }

    /// Whether the IOReport Energy Model counters were detected as frozen (macOS 27, macmon #76). Diagnostics / probe.
    public func isEnergyModelFrozen() async -> Bool { soc?.energyModelFrozen ?? false }

    // MARK: Internals

    private func sampleSoC() -> SoCMetrics? {
        if soc == nil {
            guard !socUnavailable, isAppleSilicon else { return nil }
            let clock = ContinuousClock()
            let t0 = clock.now
            soc = SoCSampler()
            let d = t0.duration(to: clock.now).components
            let ms = Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
            socSetupMilliseconds = ms
            if let soc {
                Self.log.info("IOReport SoC sampler ready: \(soc.channelCount, privacy: .public) channels in \(ms, format: .fixed(precision: 1), privacy: .public) ms")
            } else {
                socUnavailable = true
                Self.log.notice("IOReport unavailable (libIOReport or channels missing); SoC metrics disabled")
            }
        }
        return soc?.sample()
    }

    private func bootHistory() -> BootHistory {
        var boot = BootHistoryReader.read()
        guard !isAppleSilicon, let uuid = boot.bootSessionUUID else { return boot }
        switch IntelShutdownCauseCache.lookup(bootSession: uuid) {
        case .hit(let code):
            boot.intelShutdownCause = code
        case .miss:
            // 5–10 s: never awaited here (it would delay launch). The next `.boot` request (wake) picks the cached code up.
            if !intelCauseQueryRunning, let bootTime = boot.bootTime {
                intelCauseQueryRunning = true
                Task.detached(priority: .utility) { [weak self] in
                    let code = await BootHistoryReader.queryIntelShutdownCause(bootTime: bootTime)
                    await self?.finishIntelCauseQuery(code, bootSession: uuid)
                }
            }
        }
        return boot
    }

    private func finishIntelCauseQuery(_ code: Int?, bootSession uuid: String) {
        IntelShutdownCauseCache.store(code, bootSession: uuid)
        intelCauseQueryRunning = false
        Self.log.info("Intel previous shutdown cause: \(code.map(String.init) ?? "not logged", privacy: .public)")
    }

    /// Cached `system_profiler` result; the condition is re-derived with the CURRENT `PermanentFailureStatus`.
    /// nil on desktops (no AppleSmartBattery → the tool is never spawned).
    private func appleBatteryHealth() async -> AppleBatteryHealth? {
        guard let snapshot = battery.read() else { return nil }
        let pf = snapshot.permanentFailureStatus
        func current(_ h: AppleBatteryHealth?) -> AppleBatteryHealth? {
            h.map { AppleBatteryHealth(maximumCapacityPercent: $0.maximumCapacityPercent, conditionRaw: $0.conditionRaw,
                                       condition: AppleBatteryHealthReader.condition(raw: $0.conditionRaw, permanentFailureStatus: pf)) }
        }
        if let cached = appleHealth, cached.at.duration(to: .now) < (cached.value == nil ? Self.appleHealthRetry : Self.appleHealthTTL) {
            return current(cached.value)
        }
        let task: Task<AppleBatteryHealth?, Never>
        if let running = appleHealthTask {
            task = running                                      // coalesce concurrent requests onto one spawn
        } else {
            task = Task.detached(priority: .utility) { await AppleBatteryHealthReader.read(permanentFailureStatus: nil) }
            appleHealthTask = task
        }
        let value = await task.value
        appleHealthTask = nil
        appleHealth = (value, .now)
        if value == nil { Self.log.notice("system_profiler SPPowerDataType returned no battery health") }
        return current(value)
    }
}
