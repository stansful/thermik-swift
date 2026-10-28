// Probe+System.swift — OWNER: Unit 2. Manual verification of the System readers through the public `SystemSampler`.
// READ-ONLY: no SMC, no root. `loadtest` spins in-process threads (they die with the probe) for at most 50 s.
//   thermik-probe system all | machine | battery | load | ioreport | smart | boot | thermal | pmset [N] | top [N]
//                        | bench | loadtest [seconds]
// Experimental CLPC power (P2): append `-advanced.experimentalCLPCPower YES` (UserDefaults argument domain).
import Foundation
import os
import ThermikCore

extension Probe {
    static func system(_ args: [String]) async {
        let sub = args.first ?? "all"
        let n = args.dropFirst().first.flatMap { Int($0) }
        let sampler = SystemSampler()
        let machine = await sampler.start()
        switch sub {
        case "all":
            SystemProbe.printMachine(machine)
            await SystemProbe.battery(sampler)
            await SystemProbe.load(sampler, machine: machine)
            await SystemProbe.ioreport(sampler)
            await SystemProbe.smart(sampler)
            await SystemProbe.boot(sampler)
            await SystemProbe.thermal(sampler)
        case "machine": SystemProbe.printMachine(machine)
        case "battery": await SystemProbe.battery(sampler)
        case "load": await SystemProbe.load(sampler, machine: machine)
        case "ioreport": await SystemProbe.ioreport(sampler)
        case "smart": await SystemProbe.smart(sampler)
        case "boot": await SystemProbe.boot(sampler)
        case "thermal": await SystemProbe.thermal(sampler)
        case "pmset": await SystemProbe.pmset(sampler, limit: n ?? 20)
        case "top": await SystemProbe.top(sampler, limit: n ?? 10)
        case "bench": await SystemProbe.bench(sampler)
        case "loadtest": await SystemProbe.loadTest(sampler, machine: machine, seconds: min(max(n ?? 10, 1), 40))
        default:
            print("thermik-probe system all|machine|battery|load|ioreport|smart|boot|thermal|pmset [N]|top [N]|bench|loadtest [s]")
        }
    }
}

/// File-private helpers (namespaced so they cannot collide with other units' probe files after the merge).
private enum SystemProbe {
    // MARK: Sections

    static func printMachine(_ m: MachineInfo) {
        let e = m.cpuTopology.filter { $0.type == "E" }.count, p = m.cpuTopology.filter { $0.type == "P" }.count
        print("== machine")
        print("\(m.modelIdentifier) | \(m.marketingName ?? "—") | \(m.chip) | board \(m.boardID ?? "—") | macOS \(m.osVersion)"
              + (m.isTranslated ? " | Rosetta" : ""))
        print("RAM \(m.memoryBytes >> 30) GB, \(m.logicalCPUs) logical CPUs" + (m.cpuTopology.isEmpty ? "" : ", \(p)P + \(e)E")
              + ", GPU \(m.gpuName ?? "—") \(m.gpuCores.map { "\($0) cores" } ?? "")")
        for (i, l) in m.perfLevels.enumerated() {
            print("  perflevel\(i) \(l.name): \(l.logicalCPUs) logical / \(l.physicalCPUs) physical, L2 \(l.l2CacheBytes.map { "\($0 >> 20) MiB" } ?? "—")")
        }
        if !m.cpuTopology.isEmpty {
            print("  topology " + m.cpuTopology.map { "\($0.id)\($0.type)c\($0.cluster)" }.joined(separator: " "))
        }
    }

    static func battery(_ s: SystemSampler) async {
        print("== battery")
        let (frame, ms) = await timed { await s.sample(SystemSampleRequest(battery: true, powerSources: true)) }
        if let b = frame.battery {
            print("[\(f(ms, 3)) ms] charge \(b.chargePercent.map { "\($0) %" } ?? "—"), cycles \(b.cycleCount.map(String.init) ?? "—") / \(b.designCycleCount.map(String.init) ?? "—"), design \(b.designCapacity_mAh ?? -1) mAh, nominal \(b.nominalChargeCapacity_mAh ?? -1) mAh, raw max \(b.rawMaxCapacity_mAh ?? -1) mAh, raw current \(b.rawCurrentCapacity_mAh ?? -1) mAh")
            print("  health \(f(b.healthPercent, 1)) % (raw \(f(b.rawHealthPercent, 1)) %), temperature \(f(b.temperatureC, 2)) °C, \(b.voltage_mV ?? -1) mV, \(b.amperage_mA ?? 0) mA (\(f(b.batteryPowerW, 2)) W)")
            print("  charging \(b.isCharging), external \(b.externalConnected), full \(b.fullyCharged), PF \(b.permanentFailureStatus.map(String.init) ?? "—"), notChargingReason \(b.notChargingReason.map { "0x" + String($0, radix: 16) } ?? "—"), to empty \(b.minutesToEmpty.map { "\($0) min" } ?? "—"), to full \(b.minutesToFull.map { "\($0) min" } ?? "—")")
            print("  cells \(b.cellVoltages_mV) mV; adapter \(b.adapter.map { "\($0.name ?? "?") \($0.watts.map { "\($0) W" } ?? "") \($0.voltage_mV ?? 0) mV \($0.current_mA ?? 0) mA wireless \($0.isWireless)" } ?? "none")")
            print("  PowerTelemetryData: system in \(f(b.systemPowerIn_mW.map { Double($0) / 1000 }, 2)) W, system load \(f(b.systemLoad_mW.map { Double($0) / 1000 }, 2)) W, battery \(f(b.batteryPower_mW.map { Double($0) / 1000 }, 2)) W")
        } else {
            print("no AppleSmartBattery (desktop)")
        }
        if let p = frame.powerSources {
            let rem = p.timeRemaining.map { $0.isInfinite ? "unlimited (AC)" : "\(Int($0 / 60)) min" } ?? "calculating"
            print("  IOPS: \(p.kind), remaining \(rem), warning level \(p.batteryWarningLevel), low power mode \(p.lowPowerMode)")
        }
        let acc = await s.accessories()
        if !acc.isEmpty {
            print("  accessories: " + acc.map { "\($0.category ?? "?") \($0.percent.map { "\($0) %" } ?? "—")\($0.isCharging ? " charging" : "")" }.joined(separator: ", "))
        }
        let (slow, sms) = await timed { await s.slowData(.appleBatteryHealth) }
        if let h = slow.appleBatteryHealth {
            print("  Apple (system_profiler, \(f(sms, 0)) ms): maximum capacity \(h.maximumCapacityPercent.map { "\($0) %" } ?? "—"), condition \"\(h.conditionRaw ?? "—")\" → .\(h.condition)")
        } else {
            print("  Apple (system_profiler, \(f(sms, 0)) ms): unavailable")
        }
    }

    static func load(_ s: SystemSampler, machine: MachineInfo) async {
        print("== load")
        let req = SystemSampleRequest(cpuLoad: true, memory: true, gpuUsage: true)
        _ = await s.sample(req)
        try? await Task.sleep(for: .seconds(1))
        let (frame, ms) = await timed { await s.sample(req) }
        if let l = frame.cpuLoad {
            print("[\(f(ms, 3)) ms] CPU total \(f(frame.cpuTotalPercent, 1)) %, \(l.count) cores:")
            print("  " + l.enumerated().map { i, c in "\(i)\(coreType(machine, i)):\(f(c.total * 100, 0))%" }.joined(separator: " "))
        } else {
            print("CPU load: no baseline")
        }
        if let m = frame.memory {
            print("  memory: used \(gb(m.used)) GB of \(gb(m.total)) (app \(gb(m.app)), wired \(gb(m.wired)), compressed \(gb(m.compressed))), cached \(gb(m.cached)), free \(gb(m.free)), swap \(gb(m.swapUsed)) / \(gb(m.swapTotal)) GB, level \(m.freePercentLevel.map { "\($0) %" } ?? "—"), pressure \(m.pressure)")
        }
        if let g = frame.gpu {
            print("  GPU \(g.model ?? "—") (\(g.coreCount.map(String.init) ?? "?") cores): device \(g.devicePercent.map { "\($0) %" } ?? "—"), renderer \(g.rendererPercent.map { "\($0) %" } ?? "—"), tiler \(g.tilerPercent.map { "\($0) %" } ?? "—"), in use \(g.inUseSystemMemory.map { gb($0) + " GB" } ?? "—")")
        }
    }

    static func ioreport(_ s: SystemSampler) async {
        print("== ioreport")
        let req = SystemSampleRequest(soc: true)
        let (_, firstMs) = await timed { await s.sample(req) }
        guard let setup = await s.socSetupTime() else { print("IOReport not attempted"); return }
        print("first soc request \(f(firstMs, 1)) ms (subscription setup \(f(setup, 1)) ms)")
        try? await Task.sleep(for: .seconds(1))
        let (frame, ms) = await timed { await s.sample(req) }
        guard let m = frame.soc else { print("IOReport unavailable on this Mac"); return }
        printSoC(m, ms: ms)
        print("  energy model frozen: \(await s.isEnergyModelFrozen())")
    }

    static func printSoC(_ m: SoCMetrics, ms: Double) {
        print("[\(f(ms, 3)) ms] interval \(f(m.interval, 2)) s; power source \(m.power.source): CPU \(w(m.power.cpuW)), GPU \(w(m.power.gpuW)), ANE \(w(m.power.aneW)), DRAM \(w(m.power.dramW))")
        print("  clusters " + m.clusters.map { "\($0.name) ≈\(mhz($0)) \(f($0.activePercent, 0))%" }.joined(separator: " | "))
        print("  cores " + m.cores.map { "\($0.name):\(mhz($0))" }.joined(separator: " "))
        if let g = m.gpu { print("  GPU \(g.name) ≈\(mhz(g)) active \(f(g.activePercent, 0))%") }
        print("  SSD controller (ANS2) \(m.ssdControllerTempC.map { f($0, 0) + " °C" } ?? "—")")
    }

    static func smart(_ s: SystemSampler) async {
        print("== smart")
        let (slow, ms) = await timed { await s.slowData(.nvme) }
        let drives = slow.nvme ?? []
        if drives.isEmpty { print("[\(f(ms, 2)) ms] no NVMe SMART-capable drive") }
        for d in drives {
            print("[\(f(ms, 2)) ms] \(d.bsdName ?? "—") model \(d.model ?? "—") fw \(d.firmware ?? "—"): \(d.temperatureC) °C, used \(d.percentageUsed) %, spare \(d.availableSparePercent) % (threshold \(d.availableSpareThresholdPercent) %), written \(f(d.dataWrittenBytes / 1e12, 2)) TB, read \(f(d.dataReadBytes / 1e12, 2)) TB")
            print("  power-on hours \(d.powerOnHours), power cycles \(d.powerCycles), unsafe shutdowns \(d.unsafeShutdowns), media errors \(d.mediaErrors), error log entries \(d.errorLogEntries), critical warning 0x\(String(d.criticalWarning, radix: 16))")
        }
        print("  (serial number is never read)")
    }

    static func boot(_ s: SystemSampler) async {
        print("== boot")
        let (slow, ms) = await timed { await s.slowData(.boot) }
        guard let b = slow.boot else { print("no boot history"); return }
        print("[\(f(ms, 3)) ms] booted \(date(b.bootTime)), last sleep \(date(b.lastSleepTime)), last wake \(date(b.lastWakeTime)), session \(b.bootSessionUUID == nil ? "—" : "present")")
        print("  kern.shutdownreason '\(b.shutdownReason ?? "—")'")
        print("  → verdict .\(slow.shutdownVerdict.map { "\($0)" } ?? "nil") (abnormal: \(slow.shutdownVerdict?.isAbnormal ?? false))")
        print("  kern.bootreason '\(b.bootReason ?? "—")'")
        print("  wake reason '\(b.wakeReason ?? "—")', wake type '\(b.wakeType ?? "—")', last sleep reason '\(b.lastSleepReason ?? "—")', lid closed \(b.lidClosed.map { "\($0)" } ?? "—"), panic \(b.panicLogPath ?? "none"), Intel cause \(b.intelShutdownCause.map(String.init) ?? "—")")
        // Classifier spot checks (pure function; strings as seen on Apple Silicon or plausible variants).
        for r in ["wdog,reset_in_1 rst_in,reset_in_1_deassert wdog,reset_in_1 ap_restart", "wdog,reset_in_1 rst_in", "AP_SHUTDOWN",
                  "pwr_btn_long", "therm_trip", "batt_uvlo", "kernel_panic ap_restart", "gcb_off", ""] {
            print("  classify('\(r)') = .\(ShutdownClassifier.classify(reason: r))")
        }
    }

    static func thermal(_ s: SystemSampler) async {
        print("== thermal")
        let (frame, ms) = await timed { await s.sample(SystemSampleRequest()) }
        print("[\(f(ms, 3)) ms] pressure .\(frame.pressure) (raw \(frame.pressure.rawValue)), ProcessInfo.thermalState .\(frame.processThermalState)")
    }

    static func pmset(_ s: SystemSampler, limit: Int) async {
        let (events, ms) = await timed { await s.powerLog(limit: limit) }
        print("== pmset -g log: \(events.count) events in \(f(ms, 0)) ms")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        for e in events { print("  \(df.string(from: e.date)) \(e.kind): \(e.message.prefix(120))") }
    }

    static func top(_ s: SystemSampler, limit: Int) async {
        let (procs, ms) = await timed { await s.topProcesses(limit: limit) }
        print("== top processes (\(f(ms, 0)) ms incl. the 0.5 s window)")
        for p in procs { print("  \(p.pid)\t\(f(p.cpuPercent, 1)) %\t\(p.name)") }
    }

    // MARK: Timings (SPEC §5 Unit 2: ≤ 2 ms without soc, ≤ 10 ms with soc, first soc setup ≤ 300 ms)

    static func bench(_ s: SystemSampler) async {
        print("== bench (other builds may be running in parallel: numbers can be noisy)")
        let all = SystemSampleRequest(cpuLoad: true, memory: true, gpuUsage: true, soc: false, battery: true, powerSources: true)
        var plain: [Double] = []
        for _ in 0..<30 {
            let (_, ms) = await timed { await s.sample(all) }
            plain.append(ms)
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("sample(all except soc) ×30: \(stats(plain))")
        let single: [(String, SystemSampleRequest)] = [("none (thermal only)", SystemSampleRequest()),
                                                       ("cpuLoad", SystemSampleRequest(cpuLoad: true)),
                                                       ("memory", SystemSampleRequest(memory: true)),
                                                       ("gpuUsage", SystemSampleRequest(gpuUsage: true)),
                                                       ("battery", SystemSampleRequest(battery: true)),
                                                       ("powerSources", SystemSampleRequest(powerSources: true))]
        for (label, r) in single {
            var xs: [Double] = []
            for _ in 0..<15 {
                let (_, ms) = await timed { await s.sample(r) }
                xs.append(ms)
                try? await Task.sleep(for: .milliseconds(50))
            }
            print("  \(label): \(stats(xs))")
        }
        var withSoC = all; withSoC.soc = true
        let (_, first) = await timed { await s.sample(withSoC) }
        print("first sample with soc: \(f(first, 1)) ms (IOReport setup \(f(await s.socSetupTime(), 1)) ms)")
        var soc: [Double] = []
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            let (_, ms) = await timed { await s.sample(withSoC) }
            soc.append(ms)
        }
        print("sample(all incl. soc) ×20: \(stats(soc))")
        var socOnly: [Double] = []
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(500))
            let (_, ms) = await timed { await s.sample(SystemSampleRequest(soc: true)) }
            socOnly.append(ms)
        }
        print("sample(soc only) ×10: \(stats(socOnly))")
        let (_, smart) = await timed { await s.slowData(.nvme) }
        let (_, boot) = await timed { await s.slowData(.boot) }
        print("slowData(.nvme) \(f(smart, 2)) ms, slowData(.boot) \(f(boot, 2)) ms")
    }

    // MARK: Load test (≤ 60 s in total)

    static func loadTest(_ s: SystemSampler, machine: MachineInfo, seconds: Int) async {
        let threads = max(machine.perfLevels.first?.logicalCPUs ?? 12, 1)
        print("== load test: \(threads) spinning threads for \(seconds) s (+ 3 s baseline, 4 s cool-down)")
        let req = SystemSampleRequest(cpuLoad: true, gpuUsage: true, soc: true, battery: true)
        _ = await s.sample(req)
        for i in 0..<3 { try? await Task.sleep(for: .seconds(1)); await row(s, req, machine, "idle \(i + 1)") }
        let stop = OSAllocatedUnfairLock(initialState: false)
        for _ in 0..<threads {
            Thread.detachNewThread {
                var x: UInt64 = 0x9E37_79B9_7F4A_7C15
                while !stop.withLock({ $0 }) {
                    for _ in 0..<200_000 { x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
                }
                if x == 42 { print("") }                       // keep the loop observable
            }
        }
        for i in 0..<seconds {
            try? await Task.sleep(for: .seconds(1))
            await row(s, req, machine, "load \(i + 1)")
            if i == seconds / 2 {
                let top = await s.topProcesses(limit: 3)
                print("    top: " + top.map { "\($0.name) \(f($0.cpuPercent, 0)) %" }.joined(separator: ", "))
            }
        }
        stop.withLock { $0 = true }
        for i in 0..<4 { try? await Task.sleep(for: .seconds(1)); await row(s, req, machine, "cool \(i + 1)") }
        print("energy model frozen: \(await s.isEnergyModelFrozen())")
    }

    private static func row(_ s: SystemSampler, _ req: SystemSampleRequest, _ m: MachineInfo, _ label: String) async {
        let fr = await s.sample(req)
        let cores = fr.cpuLoad ?? []
        let eLoad = avg(cores.enumerated().filter { coreType(m, $0.offset) == "E" }.map { $0.element.total })
        let pLoad = avg(cores.enumerated().filter { coreType(m, $0.offset) == "P" }.map { $0.element.total })
        let clusters = fr.soc?.clusters.map { "\($0.name) \(mhz($0)) \(f($0.activePercent, 0))%" }.joined(separator: " | ") ?? "—"
        let sys = fr.battery?.systemLoad_mW.map { f(Double($0) / 1000, 1) + " W" } ?? "—"
        print("  \(label.padding(toLength: 7, withPad: " ", startingAt: 0)) CPU \(f(fr.cpuTotalPercent, 0))% (E \(f(eLoad * 100, 0))%, P \(f(pLoad * 100, 0))%) | \(clusters) | GPU \(fr.soc?.gpu.map(mhz) ?? "—") | CPU \(w(fr.soc?.power.cpuW)) GPU \(w(fr.soc?.power.gpuW)) [\(fr.soc?.power.source.rawValue ?? "—")] | system \(sys) | \(fr.pressure)")
    }

    // MARK: Formatting

    static func timed<T>(_ body: () async -> T) async -> (T, Double) {
        let clock = ContinuousClock()
        let t0 = clock.now
        let v = await body()
        let d = t0.duration(to: clock.now).components
        return (v, Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
    }

    static func f(_ v: Double?, _ digits: Int) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "—" }
    static func w(_ v: Double?) -> String { v.map { String(format: "%.2f W", $0) } ?? "—" }
    static func gb(_ b: UInt64) -> String { String(format: "%.2f", Double(b) / 1_073_741_824) }
    static func mhz(_ d: DomainFrequency) -> String { d.activePercent > 0 ? String(format: "%.0f MHz", d.mhz) : "—" }
    static func avg(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    static func coreType(_ m: MachineInfo, _ id: Int) -> String { m.cpuTopology.first { $0.id == id }?.type ?? "" }
    static func date(_ d: Date?) -> String { d.map { ISO8601DateFormatter().string(from: $0) } ?? "—" }
    static func stats(_ xs: [Double]) -> String {
        let s = xs.sorted()
        guard !s.isEmpty else { return "—" }
        return "min \(f(s.first, 3)) / median \(f(s[s.count / 2], 3)) / p90 \(f(s[min(s.count - 1, s.count * 9 / 10)], 3)) / max \(f(s.last, 3)) ms"
    }
}
