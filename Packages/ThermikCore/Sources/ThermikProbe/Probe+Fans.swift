// Probe+Fans.swift — OWNER: Unit 3. `thermik-probe fans profile|snapshot|inspect|dryrun|sim`.
//
// SAFETY: every subcommand that touches real hardware is READ-ONLY. This file never constructs a
// FanWriteSequencer or SMCFanController with a real `SMCConnection`: the only write-capable object it builds is
// over `FakeSMC` (in-memory) in `fans sim`. Belt and braces: `SMCConnection.writeRaw` refuses non-root callers, and
// the probe is never run with sudo.
import Foundation
import notify
import ThermikCore
import ThermikSMC
import ThermikSMCWriter
import ThermikHelperShared

extension Probe {
    static func fans(_ args: [String]) async {
        let rest = Array(args.dropFirst())
        switch args.first ?? "help" {
        case "profile": FanProbe.profile()
        case "snapshot": await FanProbe.snapshot(rest)
        case "inspect": FanProbe.inspect()
        case "dryrun": await FanProbe.dryRun(rest)
        case "sim": FanSim().runAll()
        default:
            print("""
            thermik-probe fans <command>        (read-only on real hardware; writes only to an in-memory FakeSMC)
              profile                 discovered fan hardware profile (scheme, fans, Mn…Mx, target type)
              snapshot [n]            live Ac / Tg / Md / Dc and Ftst, n reads at 1 Hz; names a foreign controller
              inspect                 every open SMC client and how it is classified (fan controller or not)
              dryrun [s] [--load N]   engine commands for each preset, Fixed 40 % and Max from s seconds (default 30,
                                      max 60) of live temperatures; --load N runs N busy threads meanwhile. NO writes.
              sim                     write sequence, safety monitor and engine scenarios against FakeSMC
            """)
        }
    }
}

// MARK: - Live (read-only) commands

enum FanProbe {
    static func openSMC() -> SMCConnection? {
        do { return try SMCConnection() } catch { print("SMC unavailable: \(error)"); return nil }
    }

    static func profile() {
        guard let smc = openSMC() else { return }
        let p = FanHardwareProfile.discover(smc)
        print("model \(HostInfo.modelIdentifier)  appleSilicon=\(HostInfo.isAppleSilicon)")
        print("scheme \(p.scheme)")
        print("fans \(p.fans.count)  controllable=\(p.isControllable)  allOrNothing=\(p.scheme.requiresAllOrNothing)  " +
              "Ftst key=\(p.hasFtstKey)  FS! key=\(p.hasForceBitsKey)" +
              (p.isComplete ? "" : "  UNREADABLE fans \(p.unreadableFans.map(String.init).joined(separator: ","))"))
        for f in p.fans {
            print(String(format: "  fan %d  %@ %4.0f…%4.0f rpm  target %@  mode key %@", f.index, pad(f.name, 10) as NSString,
                         f.minRPM, f.maxRPM, f.targetType.description as NSString, (f.modeKey?.description ?? "—") as NSString))
        }
    }

    static func snapshot(_ args: [String]) async {
        guard let smc = openSMC() else { return }
        let count = max(1, min(Int(args.first ?? "") ?? 1, 120))
        let p = FanHardwareProfile.discover(smc)
        print("scheme \(p.scheme)")
        guard p.isControllable || !p.fans.isEmpty else { print("no fans (FNum = 0): passively cooled"); return }
        for n in 0..<count {
            if n > 0 { try? await Task.sleep(for: .seconds(1)) }
            let st = FanReader.snapshot(smc, profile: p)
            var head = "Ftst=\(st.ftst.map(String.init) ?? "—")"
            if let fs = st.forceBits { head += String(format: "  FS!=0x%04x", fs) }
            print(count > 1 ? "[\(n + 1)/\(count)] \(head)" : head)
            for f in st.fans {
                let name = p.fan(f.index)?.name ?? "fan"
                print(String(format: "  fan %d %@ Ac %5.0f rpm  Tg %5.0f rpm  Md %@  Dc %@%@", f.index, pad(name, 10) as NSString,
                             f.actualRPM, f.targetRPM, (f.mode?.description ?? "—") as NSString,
                             (f.dutyCycle.map { String(format: "%.3f", $0) } ?? "—") as NSString,
                             (f.isOff ? "  (off — macOS stopped it)" : "") as NSString))
            }
            if st.anyManual { print("  forcing: \(st.forcingSignals.joined(separator: ", "))") }
        }
        // Decision = SMC state (signal 1). The probe is never Thermik's helper; if Thermik's helper is running and
        // controlling, forcing is ours — say so instead of blaming someone else.
        let st = FanReader.snapshot(smc, profile: p)
        guard st.anyManual else { print("no forcing: macOS controls the fans"); return }
        let clients = SMCClientInspector.classifiedClients()
        if clients.contains(where: { $0.kind == .thermikHelper }) {
            print("forcing seen while Thermik's helper holds an SMC connection: ask the helper (getState) whether it is Thermik")
        }
        let names = SMCClientInspector.suspectedFanControllers()
        let fallback = SMCClientInspector.installedFanControlHelpers()
        print("foreign controller suspected: \(names.first ?? fallback.first ?? "unknown app")" +
              (names.count > 1 ? "  (also: \(names.dropFirst().joined(separator: ", ")))" : ""))
    }

    static func inspect() {
        let clients = SMCClientInspector.classifiedClients()
        print("# \(clients.count) open SMC user clients (IORegistry AppleSMCClient.IOUserClientCreator)")
        for (c, kind) in clients.sorted(by: { $0.client.pid < $1.client.pid }) {
            print(String(format: "  pid %6d  %@ %@", c.pid, pad(c.processName, 18) as NSString, kind.description as NSString))
        }
        print("suspected fan controllers: \(SMCClientInspector.suspectedFanControllers())")
        print("installed fan-control helpers (plist presence): \(SMCClientInspector.installedFanControlHelpers())")
        if let smc = openSMC() {
            let st = FanReader.snapshot(smc, profile: FanHardwareProfile.discover(smc))
            print("SMC forcing signals: \(st.forcingSignals.isEmpty ? "none" : st.forcingSignals.joined(separator: ", "))")
        }
    }

    // MARK: Dry run

    static func dryRun(_ args: [String]) async {
        var seconds = 30
        var loadThreads = 0
        var i = 0
        while i < args.count {
            if args[i] == "--load", i + 1 < args.count { loadThreads = max(0, min(Int(args[i + 1]) ?? 0, 64)); i += 2; continue }
            if let s = Int(args[i]) { seconds = s }
            i += 1
        }
        seconds = max(5, min(seconds, 60))                         // load tests: ≤ 60 s in total
        guard let source = await LiveTemperatures.make() else { return }
        let profile = source.fanProfile
        guard profile.isControllable else { print("fans not controllable (scheme \(profile.scheme)): nothing to dry-run"); return }

        // One engine per column; plans come from the real FanPlanBuilder.
        var columns: [(name: String, config: FanUserConfig)] = FanPresetID.allCases.map { id in
            var c = FanUserConfig(); c.mode = .curve; c.curveAC = FanPresets.curve(id); return (id.rawValue, c)
        }
        var fixed = FanUserConfig(); fixed.mode = .fixed; fixed.fixedPercent = 40
        var maxCfg = FanUserConfig(); maxCfg.mode = .max
        columns += [("fixed40", fixed), ("max", maxCfg)]
        let engines = columns.map { _ in FanControlEngine(profile: profile) }

        print("dry run \(seconds) s @ 1 Hz, temperatures from \(source.origin); commands are PRINTED, NEVER SENT")
        print("fans: " + profile.fans.map { "\($0.index) \(Int($0.minRPM))…\(Int($0.maxRPM))" }.joined(separator: ", ") +
              "   scheme \(profile.scheme)")
        let load = loadThreads > 0 ? BusyLoad(threads: loadThreads) : nil
        if let load { print("load: \(load.threads) busy threads for \(seconds) s (stopped by the probe)") }
        defer { load?.stop() }

        var header = "  t  cpuAvg socHot  gpuAvg  top4  rawMax press |"
        for c in columns { header += " " + c.name.padding(toLength: 11, withPad: " ", startingAt: 0) + "|" }
        print(header)
        var stats: [AggregateKind: (min: Double, max: Double)] = [:]
        let clock = ContinuousClock()
        var next = clock.now
        for t in 0..<seconds {
            let s = await source.read()
            for (k, v) in s.smoothed.values {
                let cur = stats[k] ?? (v, v); stats[k] = (min(cur.min, v), max(cur.max, v))
            }
            var line = String(format: "%3d ", t) + [s.smoothed[.cpuAverage], s.smoothed[.socHottest], s.smoothed[.gpuAverage],
                                                     s.smoothed[.safetyTop4], s.raw[.rawHottestDie]].map { pad(f($0), 6, left: true) }
                .joined(separator: " ") + " " + pad(s.pressure.short, 5) + " |"
            for (j, c) in columns.enumerated() {
                let plan = FanPlanBuilder.plan(config: c.config, power: .ac, profile: profile)
                var temps: [TemperatureSource: Double] = [:]
                for src in plan.referencedSources { if let v = s.value(src) { temps[src] = v } }
                let out = engines[j].tick(now: s.date, temperatures: temps, safetyTempC: s.smoothed[.safetyTop4],
                                          rawHottestC: s.raw[.rawHottestDie], pressure: s.pressure, plan: plan)
                line += " " + commandText(out, profile).padding(toLength: 11, withPad: " ", startingAt: 0) + "|"
            }
            print(line)
            next = next.advanced(by: .seconds(1))
            try? await clock.sleep(until: next, tolerance: .milliseconds(50))
        }
        print("ranges (smoothed °C): " + [AggregateKind.cpuAverage, .cpuHottest, .gpuAverage, .socHottest, .safetyTop4]
            .compactMap { k in stats[k].map { "\(k.rawValue) \(String(format: "%.1f…%.1f", $0.min, $0.max))" } }
            .joined(separator: "  "))
        let live = source.fanState()
        print("live fans now: " + live.fans.map { String(format: "%d: %.0f rpm %@", $0.index, $0.actualRPM, $0.mode?.description ?? "—") }
            .joined(separator: ", ") + (live.anyManual ? "  [forced by another app: \(live.forcingSignals.joined(separator: ", "))]" : ""))
    }

    static func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }

    /// "sys" or "4006" (linked, equal) or "3121/3200".
    static func commandText(_ out: [Int: FanCommand], _ profile: FanHardwareProfile) -> String {
        let cmds = profile.fans.map { out[$0.index] ?? .system }
        if cmds.allSatisfy({ $0 == .system }) { return "sys" }
        let parts = cmds.map { c -> String in if case .rpm(let r) = c { return String(format: "%.0f", r) }; return "sys" }
        return Set(parts).count == 1 ? parts[0] : parts.joined(separator: "/")
    }
}

extension ThermalPressure {
    var short: String {
        switch self { case .nominal: "nom"; case .moderate: "mod"; case .heavy: "heavy"; case .trapping: "trap"; case .sleeping: "crit" }
    }
}

/// N busy threads (dry-run load test). Stopped by `stop()`; the probe never runs them longer than 60 s.
final class BusyLoad: @unchecked Sendable {   // `running` is guarded by `lock`
    let threads: Int
    private let lock = NSLock()
    private var running = true
    init(threads: Int) {
        self.threads = threads
        for _ in 0..<threads {
            Thread.detachNewThread { [self] in
                var x: UInt64 = 0x9E37_79B9_7F4A_7C15
                while self.isRunning {
                    for _ in 0..<2_000_000 { x ^= x << 13; x ^= x >> 7; x ^= x << 17 }
                }
                if x == 42 { print("") }                        // keep the loop from being optimized away
            }
        }
    }
    var isRunning: Bool { lock.withLock { running } }
    func stop() { lock.withLock { running = false } }
}

/// One reading of everything the engine consumes.
struct TemperatureSample {
    let date: Date
    var smoothed: AggregateValues          // what SensorStore.aggregates would hold (EMA, SPEC §2.5.6)
    var raw: AggregateValues               // SensorStore.rawAggregates
    var sensors: [SensorID: Double]
    var pressure: ThermalPressure
    func value(_ s: TemperatureSource) -> Double? {
        switch s { case .aggregate(let k): smoothed[k]; case .sensor(let id): sensors[id] }
    }
}

/// Live temperatures for the dry run: Unit 1's `SensorSampler` + `SensorAggregator` (read-only).
final class LiveTemperatures {
    let origin: String
    let fanProfile: FanHardwareProfile
    private let smc: SMCConnection?
    private let sampler: SensorSampler
    private let inventory: SensorInventory
    private var ema: [AggregateKind: Double] = [:]
    private var lastDate: Date?
    private var pressureToken: Int32 = 0

    private init(origin: String, fanProfile: FanHardwareProfile, smc: SMCConnection?, sampler: SensorSampler,
                 inventory: SensorInventory) {
        self.origin = origin; self.fanProfile = fanProfile; self.smc = smc; self.sampler = sampler
        self.inventory = inventory
        if notify_register_check("com.apple.system.thermalpressurelevel", &pressureToken) != UInt32(NOTIFY_STATUS_OK) { pressureToken = -1 }
    }

    static func make() async -> LiveTemperatures? {
        let sampler = SensorSampler()
        do {
            let inv = try await sampler.start()
            guard !inv.sensors.isEmpty else { print("SensorSampler found no temperature sensors: no live temperatures"); return nil }
            return LiveTemperatures(origin: "SensorSampler (\(inv.catalogStatus))", fanProfile: inv.fanProfile, smc: try? SMCConnection(),
                                    sampler: sampler, inventory: inv)
        } catch {
            print("sensor discovery failed (\(error)): no live temperatures")
            return nil
        }
    }

    func fanState() -> FanControlState {
        guard let smc else { return FanControlState(ftst: nil, forceBits: nil, fans: []) }
        return FanReader.snapshot(smc, profile: fanProfile)
    }

    func read() async -> TemperatureSample {
        let now = Date()
        let inv = inventory
        let frame = await sampler.sample(SampleRequest(sensorIDs: inv.sensors.map(\.id), includeFans: false, includePower: false))
        let sensors = frame.values
        let raw = SensorAggregator(inventory: inv).aggregates(frame.values, visible: Set(inv.sensors.filter(\.isVisibleByDefault).map(\.id)))
        // SensorStore-like smoothing: τ 2.8 s, 1.5 s for the "hottest" kinds (SPEC §2.5.6).
        let dt = lastDate.map { max(now.timeIntervalSince($0), 0.1) } ?? 1
        lastDate = now
        var smoothed = AggregateValues()
        for (k, v) in raw.values {
            let tau: Double = [.cpuHottest, .gpuHottest, .highestAll, .rawHottestDie].contains(k) ? 1.5 : 2.8
            let prev = ema[k]
            let s = prev.map { $0 + (1 - exp(-dt / tau)) * (v - $0) } ?? v
            ema[k] = s
            smoothed.values[k] = s
        }
        var state: UInt64 = 0
        if pressureToken >= 0 { notify_get_state(pressureToken, &state) }
        return TemperatureSample(date: now, smoothed: smoothed, raw: raw, sensors: sensors,
                                 pressure: ThermalPressure(rawValue: state) ?? .nominal)
    }
}

// MARK: - Offline simulator (FakeSMC only)

final class FanSim {
    private var passed = 0
    private var failed = 0

    func check(_ ok: Bool, _ what: String) {
        if ok { passed += 1; print("   PASS  \(what)") } else { failed += 1; print("   FAIL  \(what)") }
    }

    func runAll() {
        print("thermik-probe fans sim — FakeSMC (in memory); no AppleSMC connection is opened")
        sequencerScenarios()
        controllerScenarios()
        safetyScenarios()
        inspectorScenarios()
        engineScenarios()
        planAndPresetScenarios()
        discoveryScenarios()
        print("\nsim result: \(passed) passed, \(failed) failed")
    }

    // MARK: Discovery with flaky reads

    /// FakeSMC whose reads of some keys fail (SMC "not readable") a given number of times; -1 = always.
    final class FlakySMC: SMCReading, @unchecked Sendable {   // `failures` is guarded by `lock`
        private let base: FakeSMC
        private let lock = NSLock()
        private var failures: [FourCC: Int]
        init(_ base: FakeSMC, failing: [FourCC: Int]) { self.base = base; failures = failing }
        private func maybeFail(_ key: FourCC) throws {
            try lock.withLock {
                guard let n = failures[key], n != 0 else { return }
                if n > 0 { failures[key] = n - 1 }
                throw SMCError.firmware(SMCResultCode.notReadable.rawValue, key: key)
            }
        }
        func keyInfo(_ key: FourCC) throws -> SMCKeyInfo { try maybeFail(key); return try base.keyInfo(key) }
        func readRaw(_ key: FourCC) throws -> (SMCKeyInfo, [UInt8]) { try maybeFail(key); return try base.readRaw(key) }
        func keyCount() throws -> Int { try base.keyCount() }
        func key(at index: Int) throws -> FourCC { try base.key(at: index) }
    }

    func discoveryScenarios() {
        print("\n=== Fan discovery with transient / persistent read errors ===")
        func profile(_ gen: FakeSMC.Generation, _ failing: [FourCC: Int]) -> FanHardwareProfile {
            FanHardwareProfile.discover(FlakySMC(FakeSMC(gen, clock: SimulatedClock()), failing: failing), appleSilicon: gen.isAppleSilicon)
        }
        let transient = profile(.m4, ["F1Mx": 2, "FNum": 1, "Ftst": 1])
        check(transient.fans.count == 2 && transient.isComplete && transient.isControllable && transient.scheme.requiresAllOrNothing,
              "M4: FNum, Ftst and F1Mx fail once or twice -> retried: 2 fans, Ftst scheme, controllable")
        let lost = profile(.m4, ["F1Mx": -1])
        check(lost.fans.map(\.index) == [0] && lost.unreadableFans == [1] && !lost.isControllable,
              "M4: F1Mx never readable -> fan 1 unreadable, profile NOT controllable (all-or-nothing)")
        let plan = FanPlanBuilder.plan(config: { var c = FanUserConfig(); c.mode = .max; return c }(), power: .ac, profile: lost)
        check(plan.shared == .system, "incomplete Ftst profile: the plan stays System")
        let m5 = profile(.m5, ["F1Mx": -1])
        check(m5.fans.map(\.index) == [0] && !m5.isComplete && m5.isControllable, "M5 (per-fan, no Ftst): fan 0 stays controllable")
        let fanless = profile(.m4, ["FNum": -1])
        check(fanless.fans.isEmpty && !fanless.isControllable, "FNum never readable -> no fans (monitoring only)")
    }

    // MARK: Sequencer (FANS §5.4)

    func run(_ title: String, _ gen: FakeSMC.Generation,
                    _ body: (FanWriteSequencer, FakeSMC, SimulatedClock) throws -> Void) {
        print("\n=== \(title) ===")
        let clock = SimulatedClock()
        let smc = FakeSMC(gen, clock: clock)
        let profile = FanHardwareProfile.discover(smc, appleSilicon: gen.isAppleSilicon)
        print("profile scheme: \(profile.scheme)  fans \(profile.fans.map { "\(Int($0.minRPM))…\(Int($0.maxRPM)) \($0.targetType)" })")
        let seq = FanWriteSequencer(smc: smc, profile: profile, clock: clock, log: { print("   log: \($0)") })
        do { try body(seq, smc, clock) } catch { print("   ERROR: \(error)") }
        printTrace(smc, profile: profile, owned: seq.ownedFans, ftstSetByUs: seq.ftstSetByUs)
    }

    func printTrace(_ smc: FakeSMC, profile: FanHardwareProfile, owned: Set<Int>, ftstSetByUs: Bool) {
        let log = smc.writeLog
        print("   writes (\(log.count)):")
        // Long retry runs are elided in the middle (every write is still counted).
        if log.count > 14 {
            log.prefix(4).forEach { print("     \($0)") }
            print("     … \(log.count - 12) more …")
            log.suffix(8).forEach { print("     \($0)") }
        } else { log.forEach { print("     \($0)") } }
        print("   final: \(state(smc, profile)) owned=\(owned.sorted()) ftstSetByUs=\(ftstSetByUs)")
    }

    func state(_ smc: FakeSMC, _ profile: FanHardwareProfile) -> String {
        let modes = profile.fans.compactMap { f in f.modeKey.flatMap { smc.bytes($0)?.first } }
        let ftst = smc.bytes(FanHardwareProfile.ftstKey)?.first.map { String($0) } ?? "—"
        let fs = smc.bytes(FanHardwareProfile.forceBitsKey).map { $0.map { String(format: "%02x", $0) }.joined() } ?? "—"
        return "modes=\(modes) Ftst=\(ftst) FS!=\(fs)"
    }

    func mode(_ smc: FakeSMC, _ key: FourCC?) -> UInt8? { key.flatMap { smc.bytes($0)?.first } }

    func sequencerScenarios() {
        run("M4: unlock via Ftst after the 3.5 s fake delay, clamp high/low, release last fan clears Ftst", .m4) { seq, smc, clock in
            let a0 = try seq.setTarget(0, rpm: 99_999)
            let unlockedAt = clock.now().timeIntervalSince1970
            let a1 = try seq.setTarget(1, rpm: 10)
            print("   applied fan0 = \(a0), fan1 = \(a1)")
            check(a0 == 5777, "99999 rpm clamped to Mx 5777")
            check(a1 == 1350, "10 rpm clamped to Mn 1350")
            check(unlockedAt >= 3.5 && unlockedAt <= 4.0, String(format: "fan 0 manual after the unlock (t=%.2f s)", unlockedAt))
            check(smc.writeLog.contains { $0.contains("F0Md=01 -> 0x82") }, "direct mode write refused with 0x82 while mode 3")
            check(smc.bytes("F0Tg") == SMCCodec.encodeFloat32LE(5777), "F0Tg = 0088b445 (5777.0 flt LE)")
            try seq.release(0)
            check(smc.bytes(FanHardwareProfile.ftstKey) == [1], "Ftst stays 1 while fan 1 is still owned")
            try seq.release(1)
            check(smc.writeLog.last?.hasSuffix("Ftst=00") == true, "releasing the last fan writes Ftst=0")
            check(mode(smc, "F0Md") == 3 && mode(smc, "F1Md") == 3, "macOS reclaims both fans (mode 3)")
        }
        run("M4 under load: thermalmonitord never yields -> timeout after 12 s, Ftst cleaned up", .m4Refusing) { seq, smc, clock in
            do { _ = try seq.setTarget(0, rpm: 3000); check(false, "unlock must time out") } catch let e as FanWriteError {
                print("   expected error: \(e)")
                if case .unlockTimeout = e { check(true, "unlockTimeout after \(Int(clock.now().timeIntervalSince1970)) s") } else { check(false, "unlockTimeout") }
                check(e.helperErrorCode == .unlockTimeout, "maps to HelperErrorCode.unlockTimeout (10)")
            }
            check(smc.bytes(FanHardwareProfile.ftstKey) == [0] && !seq.ftstSetByUs, "Ftst cleared, nothing owned")
        }
        run("M1: direct write sticks (Ftst present but unused)", .m1Direct) { seq, smc, _ in
            _ = try seq.setTarget(0, rpm: 3000)
            check(!smc.writeLog.contains { $0.contains("Ftst") }, "no Ftst write")
            _ = seq.releaseAll(force: false, reason: "test")
            check(mode(smc, "F0Md") == 0, "fan 0 back to mode 0")
        }
        run("M4 Max: a stopped fan refuses F%dMd=0 (0x82) -> spun up to Mn first, then handed back", .m1Direct) { seq, smc, clock in
            smc.refusesReleaseWhileStopped = true
            smc.spinUpDelay = 1.2
            _ = try seq.setTarget(0, rpm: 0); _ = try seq.setTarget(1, rpm: 0)
            check(seq.appliedRPM[0] == 0 && seq.appliedRPM[1] == 0, "rpm 0 stops both fans")
            let start = clock.now()
            let failures = seq.releaseAll(force: false, reason: "quit while stopped")
            let took = clock.now().timeIntervalSince(start)
            print(String(format: "   failures: %@, release took %.2f s", failures.description, took))
            check(failures.isEmpty && mode(smc, "F0Md") == 0 && mode(smc, "F1Md") == 0 && seq.ownedFans.isEmpty,
                  "both stopped fans back to System")
            check(took < 2, String(format: "both fans spin up together: %.2f s for a 1.2 s spin-up, not twice that", took))
            let log = smc.writeLog
            check(log.contains { $0.contains("F0Md=00 -> 0x82") }, "F0Md=0 refused while fan 0 still stood")
            let tg = log.lastIndex { $0.contains("F0Tg=") }, md = log.lastIndex { $0.hasSuffix("F0Md=00") }
            check(tg != nil && md != nil && tg! < md!, "F0Tg set to the minimum before the accepted F0Md=0")
        }
        run("M1 variant: direct write reclaimed -> escalate to Ftst", .m1Reclaims) { seq, smc, _ in
            _ = try seq.setTarget(0, rpm: 3000)
            check(smc.writeLog.contains { $0.contains("Ftst=01") }, "escalated to the Ftst unlock")
            _ = seq.releaseAll(force: false, reason: "test")
            check(smc.bytes(FanHardwareProfile.ftstKey) == [0], "Ftst cleared on release")
        }
        run("M5: lowercase F%dmd, no Ftst, direct", .m5) { seq, smc, _ in
            _ = try seq.setTarget(0, rpm: 4000); _ = try seq.setTarget(1, rpm: 4000)
            check(smc.writeLog.first?.contains("F0md=01") == true, "lowercase mode key written")
            check(seq.allowList.contains("F0md") && !seq.allowList.contains("F0Md") && !seq.allowList.contains("Ftst"),
                  "allow-list = lowercase mode keys, no Ftst")
            _ = seq.releaseAll(force: false, reason: "lease expired")
            check(mode(smc, "F0md") == 0 && mode(smc, "F1md") == 0, "both fans released")
        }
        run("Intel pre-T2: FS! bitmask + fpe2", .intelPreT2) { seq, smc, _ in
            _ = try seq.setTarget(1, rpm: 3500)
            let tg = smc.bytes("F1Tg") ?? []
            print("   F1Tg bytes: \(tg.map { String(format: "%02x", $0) }.joined())")
            check(tg == [0x36, 0xb0], "3500 rpm -> fpe2 36b0 (big-endian 14.2)")
            check(smc.bytes(FanHardwareProfile.forceBitsKey) == [0, 2], "FS! bit 1 set")
            _ = seq.releaseAll(force: false, reason: "sigterm")
            check(smc.bytes(FanHardwareProfile.forceBitsKey) == [0, 0], "FS! cleared")
        }
        run("Intel T2: F%dMd + flt", .intelT2) { seq, smc, _ in
            _ = try seq.setTarget(0, rpm: 2500)
            check(smc.bytes("F0Tg") == SMCCodec.encodeFloat32LE(2500), "flt target 2500")
            try seq.release(0)
            check(mode(smc, "F0Md") == 0, "fan 0 back to mode 0")
        }
        run("Allow-list and argument checks", .m4) { seq, smc, _ in
            do { try seq.ensureManual(7); check(false, "fan 7 must be refused") } catch { check("\(error)" == "no fan 7", "invalid fan index refused (\(error))") }
            do { _ = try seq.setTarget(0, rpm: .nan); check(false, "NaN must be refused") } catch { check(true, "NaN rpm refused (\(error))") }
            do { _ = try seq.setTarget(0, rpm: -1); check(false, "negative must be refused") } catch { check(true, "negative rpm refused") }
            check(seq.allowList == ["F0Md", "F1Md", "F0Tg", "F1Tg", "Ftst"], "allow-list = {F0Md, F1Md, F0Tg, F1Tg, Ftst}")
            check(!seq.allowList.contains("FOFC"), "writable unknown key FOFC is not allow-listed")
            check(smc.writeLog.isEmpty, "no write happened")
        }
    }

    // MARK: SMCFanController (FanControlling) on FakeSMC

    func makeController(_ gen: FakeSMC.Generation, clock: SimulatedClock) -> (SMCFanController, FakeSMC) {
        let smc = FakeSMC(gen, clock: clock)
        let c = SMCFanController(device: smc, appleSilicon: gen.isAppleSilicon, clock: clock, log: { print("   log: \($0)") })
        c.markerPath = nil
        return (c, smc)
    }

    func controllerScenarios() {
        do {
            print("\n=== Startup recovery after SIGKILL (marker found: force release of the previous instance's state) ===")
            let clock = SimulatedClock()
            let smc = FakeSMC(.m4, clock: clock)
            // A previous helper instance left Ftst=1 and fan 0 manual (written with the raw fake, not the sequencer).
            try? smc.writeRaw(FanHardwareProfile.ftstKey, [1]); clock.sleep(4)
            try? smc.writeRaw("F0Md", [1]); try? smc.writeRaw("F0Tg", SMCCodec.encodeFloat32LE(1350))
            smc.appendLog("---- helper restarted ----")
            let fresh = SMCFanController(device: smc, appleSilicon: true, clock: clock, log: { print("   log: \($0)") })
            fresh.markerPath = nil
            fresh.adoptPersistedState(ftstSetByUs: true)
            check(!fresh.foreignControlSuspected(), "own leftover state is not a foreign controller while recovering")
            let failures = fresh.restoreAll(force: true, reason: "startupRecovery")
            print("   failures: \(failures)")
            printTrace(smc, profile: fresh.profile, owned: fresh.ownedFans, ftstSetByUs: fresh.ftstSetByUs)
            check(failures.isEmpty && smc.bytes(FanHardwareProfile.ftstKey) == [0] && mode(smc, "F0Md") == 3, "fans restored to System (mode 3, Ftst 0)")
        }
        do {
            print("\n=== Foreign controller (I10): another app forces the fans ===")
            let clock = SimulatedClock()
            let (c, smc) = makeController(.m4, clock: clock)
            check(!c.foreignControlSuspected(), "idle M4 (mode 3, Ftst 0): not suspected")
            smc.simulateForeignController()
            print("   SMC: \(state(smc, c.profile))")
            check(c.foreignControlSuspected(), "Ftst=1 + modes=1 with no marker: suspected")
            let marker = NSTemporaryDirectory() + "thermik-probe-marker-\(getpid())"
            FileManager.default.createFile(atPath: marker, contents: Data("{}".utf8))
            c.markerPath = marker
            check(!c.foreignControlSuspected(), "marker present (state may be Thermik's): not suspected")
            try? FileManager.default.removeItem(atPath: marker)
            c.markerPath = nil
            check(c.evaluateSafety() == .normal(hottestC: nil), "not controlling: the safety monitor does not read the SMC")
        }
        do {
            print("\n=== Reclaimed fan: re-assert throttled to once per 5 s ===")
            let clock = SimulatedClock()
            let (c, smc) = makeController(.m4, clock: clock)
            _ = try? c.setManual(0, targetRPM: 3000); _ = try? c.setManual(1, targetRPM: 3000)
            print(String(format: "   both fans manual at t=%.2f s; states %@", clock.now().timeIntervalSince1970,
                         c.fanStates().map { "\($0.index):\($0.modeRaw ?? -1)/\(Int($0.actualRPM))" }.joined(separator: " ")))
            smc.simulateReclaim(fan: 0)
            check(c.reclaimedFans() == [0], "fan 0 reported as reclaimed")
            do { _ = try c.setManual(0, targetRPM: 3000); check(false, "re-assert inside 5 s must be throttled") } catch let e as FanWriteError {
                if case .reclaimedTooSoon = e { check(true, "re-assert inside 5 s refused (\(e))") } else { check(false, "\(e)") }
            } catch { check(false, "\(error)") }
            clock.advance(1.5)
            let applied = try? c.setManual(0, targetRPM: 3000)
            check(applied == 3000 && c.reclaimedFans().isEmpty, "re-asserted after 5 s")
            let failures = c.restoreAll(force: false, reason: "test")
            check(failures.isEmpty && !c.isControlling && mode(smc, "F0Md") == 3, "restoreAll: System again")
        }
    }

    // MARK: ThermalSafetyMonitor (I8/I9)

    func safetyScenarios() {
        print("\n=== Thermal safety monitor (I8 override, I9 sensor failure) ===")
        let clock = SimulatedClock()
        let (c, smc) = makeController(.m4, clock: clock)
        // M4 Max-like die keys: live P/E/GPU probes, a gated P triplet, 40.0 placeholders, a peak-hold Tf key.
        let live: [FourCC] = ["Tp1i", "Tp1j", "Tp1k", "Tp1m", "Tpx9", "Te05", "Te06", "Tg05", "Tg0K"]
        for (n, k) in live.enumerated() { smc.setTemperature(k, 60 + Double(n)) }
        smc.setTemperature("Tp00", -4.0); smc.setTemperature("Tp01", 1.9); smc.setTemperature("Tp02", 0.0)   // gated triplet
        smc.setTemperature("Tp0S", 40.0)                                                                       // placeholder
        smc.setTemperature("Tf06", 93.36)                                                                      // peak-hold, not a reading
        smc.setTemperature("Tp0X", 99.0)                                                                       // will stay static
        _ = try? c.setManual(0, targetRPM: 2000); _ = try? c.setManual(1, targetRPM: 2000)
        let keys = c.monitoredSafetyKeys
        print("   monitored: \(keys.map(\.description).joined(separator: " "))")
        check(!keys.contains("Tf06"), "Tf06 (peak-hold, 93 °C) is not in the die set")
        var verdict = c.evaluateSafety()
        print("   idle: \(text(verdict))")
        if case .normal(let h) = verdict { check(h == 99, "gated (-4/1.9/0) and 40.0 values ignored; hottest = static Tp0X 99 for now") } else { check(false, "idle verdict") }
        // Live probes jitter like real ones (±0.1 °C per tick); Tp0X never changes.
        var tick = 0
        func step(_ base: Double, spread: Double) {
            tick += 1
            for (n, k) in live.enumerated() { smc.setTemperature(k, base + spread * Double(n) + (tick % 2 == 0 ? 0.1 : -0.1)) }
            clock.advance(1)
        }
        for _ in 0..<31 { step(60, spread: 1); _ = c.evaluateSafety() }
        step(60, spread: 1)
        verdict = c.evaluateSafety()
        if case .normal(let h) = verdict { check((h ?? 99) < 70, "Tp0X unchanged for > 30 s is dropped (hottest now \(h.map { String(format: "%.1f", $0) } ?? "—"))") } else { check(false, "static key") }
        func heat(_ t: Double) { step(t, spread: 0) }
        heat(104); verdict = c.evaluateSafety(); print("   104 °C: \(text(verdict))")
        if case .override = verdict { check(true, "top-4 ≥ 103 °C -> override (every fan to Mx)") } else { check(false, "override at 104") }
        heat(96); verdict = c.evaluateSafety()
        if case .override = verdict { check(true, "96 °C: override held (release below 95)") } else { check(false, "hold at 96") }
        heat(94); verdict = c.evaluateSafety(); print("   94 °C: \(text(verdict))")
        if case .normal = verdict { check(true, "94 °C: released") } else { check(false, "release at 94") }
        for k in live + ["Tp0X"] { smc.removeKey(k) }
        var verdicts: [SafetyVerdict] = []
        for _ in 0..<3 { clock.advance(1); verdicts.append(c.evaluateSafety()) }
        print("   no readable die sensor: \(verdicts.map(text).joined(separator: ", "))")
        check(verdicts.last == .sensorFailure && verdicts.first != .sensorFailure, "3 ticks without a reading -> sensorFailure (restore System)")
        _ = c.restoreAll(force: false, reason: "sensorFailure")
    }

    // MARK: SMCClientInspector classification (rule: a non-fan helper is never named)

    func inspectorScenarios() {
        print("\n=== SMC client naming (IOUserClientCreator + proc_pidpath), offline ===")
        let ph = "/Library/PrivilegedHelperTools/"
        let cases: [(String, String?, String?)] = [
            ("TG Pro", "/Applications/TG Pro.app/Contents/MacOS/TG Pro", "TG Pro"),
            ("com.tunabellysof", ph + "com.tunabellysoftware.TGFanHelper", "TG Pro"),
            ("com.tunabellysof", nil, "TG Pro"),
            ("com.apphousekitc", ph + "com.apphousekitchen.aldente-pro.helper", nil),
            ("com.apphousekitc", nil, nil),
            ("AlDente", "/Applications/AlDente.app/Contents/MacOS/AlDente", nil),
            ("com.crystalidea.", ph + "com.crystalidea.macsfancontrol.smcwrite", "Macs Fan Control"),
            ("eu.exelban.Stats", ph + "eu.exelban.Stats.SMC.Helper", "Stats"),
            ("org.example.fanc", ph + "org.example.fanctl.helper", "org.example.fanctl.helper"),
            ("dev.orbstack.Orb", ph + "dev.orbstack.OrbStack.privhelper", nil),
            ("app.thermik.help", ph + "app.thermik.helper", nil),
            ("systemstats", "/usr/sbin/systemstats", nil),
        ]
        for (name, path, expected) in cases {
            let kind = SMCClientInspector.classify(processName: name, executablePath: path)
            check(kind.reportedName == expected, "\(name) \(path.map { "@ \(($0 as NSString).lastPathComponent)" } ?? "(no path)") -> \(kind)")
        }
    }

    // MARK: Engine (FANS §11.4 + SPEC §2.9.2 additions)

    static let simProfile: FanHardwareProfile = {
        var p = FanHardwareProfile(fans: (0..<2).map { FanDescriptor(index: $0, name: "F\($0)", minRPM: 1350, maxRPM: 5777, targetType: .flt,
                                                                    modeKey: .fan(FanHardwareProfile.modeUpper, $0)) },
                                   scheme: .appleSilicon(modeKeyTemplate: FanHardwareProfile.modeUpper, hasFtst: true))
        p.hasFtstKey = true
        return p
    }()

    func engineScenarios() {
        print("\n=== Engine strategies (synthetic ramp 45 -> 98 -> 45 °C at 1 °C/s, 1 s ticks) ===")
        let sensor = TemperatureSource.sensor(.smc("Tp01"))
        let strategies: [(String, FanStrategy)] = [
            ("fixed 40%", .fixedPercent(40)),
            ("autoMax 80", .autoMax(sensor: sensor, thresholdC: 80, hysteresisC: 5, minHoldSeconds: 10)),
            ("autoBoost 60-90/10s", .autoBoost(sensor: sensor, lowC: 60, highC: 90, minPercent: 0, maxPercent: 100, gradualSeconds: 10, hysteresisC: 3)),
            ("curve", .curve(sensor: sensor, points: [CurvePoint(55, 0), CurvePoint(70, 30), CurvePoint(85, 70), CurvePoint(95, 100)],
                             hysteresisC: 3, below: .system, smoothing: Smoothing(riseTau: 2, fallTau: 12),
                             slew: Slew(up: 25, down: 2, hold: 10))),
        ]
        var ramp: [Double] = []
        for i in 0...53 { ramp.append(45 + Double(i)) }
        for _ in 0..<10 { ramp.append(98) }
        for i in 0...53 { ramp.append(98 - Double(i)) }
        for _ in 0..<60 { ramp.append(45) }
        var header = "  t   temp |"
        for (n, _) in strategies { header += " " + n.padding(toLength: 20, withPad: " ", startingAt: 0) + "|" }
        print(header)
        let engines = strategies.map { _ in FanControlEngine(profile: Self.simProfile) }
        var table: [[FanCommand]] = []
        for (i, temp) in ramp.enumerated() {
            var line = String(format: "%4d %5.1f |", i, temp)
            var row: [FanCommand] = []
            for (j, (_, strat)) in strategies.enumerated() {
                var plan = FanPlan(); plan.shared = strat
                let out = engines[j].tick(now: Date(timeIntervalSince1970: Double(i)), temperatures: [sensor: temp],
                                          safetyTempC: temp, rawHottestC: temp, pressure: .nominal, plan: plan)
                row.append(out[0] ?? .system)
                line += " " + "\(out[0] ?? .system)".padding(toLength: 20, withPad: " ", startingAt: 0) + "|"
            }
            table.append(row)
            if i % 6 == 0 { print(line) }
        }
        func rpm(_ c: FanCommand) -> Double? { if case .rpm(let r) = c { return r }; return nil }
        check(rpm(table[24][0]) == 3121, "fixed 40 % = 3121 rpm below the floor zone")
        check((rpm(table[54][0]) ?? 0) > 4500, "fixed: safety floor kicks in near 98 °C (\(table[54][0]))")
        check(table[30][1] == .system && rpm(table[36][1]) == 5777 && table[96][1] == .system, "autoMax: System -> 5777 at 80 °C -> System after cooling")
        check(rpm(table[78][3]) == 5777, "curve: hold at max while cooling (t=78)")
        check((rpm(table[96][3]) ?? 0) < 5777 && (rpm(table[96][3]) ?? 0) > (rpm(table[114][3]) ?? 0), "curve: slow descent after the hold")
        check(table.last?[3] == .system, "curve: released to System at 45 °C")

        print("\n=== All-or-nothing on Ftst hardware ===")
        var plan = FanPlan(); plan.linked = false; plan.perFan = [0: .fixedPercent(60), 1: .system]
        let e2 = FanControlEngine(profile: Self.simProfile)
        let aon = e2.tick(now: Date(), temperatures: [:], safetyTempC: 50, rawHottestC: 50, pressure: .nominal, plan: plan)
        print("   fan0 fixed 60 %, fan1 System -> \(aon.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))")
        check(aon[0] == .rpm(4006) && aon[1] == .rpm(4006), "both fans 4006 rpm")
        var m5 = FanHardwareProfile(fans: Self.simProfile.fans, scheme: .appleSilicon(modeKeyTemplate: FanHardwareProfile.modeLower, hasFtst: false))
        m5.hasFtstKey = false
        let e3 = FanControlEngine(profile: m5)
        let per = e3.tick(now: Date(), temperatures: [:], safetyTempC: 50, rawHottestC: 50, pressure: .nominal, plan: plan)
        check(per[0] == .rpm(4006) && per[1] == .system, "M5 (no Ftst): per-fan control, fan 1 stays System")

        print("\n=== Safety latch, sensor loss, thermal guard, deadband ===")
        let t0 = Date(timeIntervalSince1970: 1000)
        var fixedPlan = FanPlan(); fixedPlan.shared = .fixedPercent(20)
        let e4 = FanControlEngine(profile: Self.simProfile)
        _ = e4.tick(now: t0, temperatures: [:], safetyTempC: 70, rawHottestC: 80, pressure: .nominal, plan: fixedPlan)
        let spike = e4.tick(now: t0 + 1, temperatures: [:], safetyTempC: 72, rawHottestC: 106, pressure: .nominal, plan: fixedPlan)
        check(spike[0] == .rpm(5777) && e4.safetyLatched, "raw hottest 106 °C ≥ 105 -> every forced fan 100 %")
        var held = true
        for s in 2...9 { held = held && e4.tick(now: t0 + Double(s), temperatures: [:], safetyTempC: 70, rawHottestC: 80, pressure: .nominal, plan: fixedPlan)[0] == .rpm(5777) }
        check(held, "latch holds ≥ 10 s after a single raw spike")
        let after = e4.tick(now: t0 + 12, temperatures: [:], safetyTempC: 70, rawHottestC: 80, pressure: .nominal, plan: fixedPlan)
        check(!e4.safetyLatched && after[0] == .rpm(2235), "released below critical − hysteresis (94 °C) after the hold -> back to 20 % (\(after[0] ?? .system))")
        let sysPlan = FanPlan()
        let sys = e4.tick(now: t0 + 13, temperatures: [:], safetyTempC: 110, rawHottestC: 110, pressure: .nominal, plan: sysPlan)
        check(sys[0] == .system, "System fans stay System even when latched (macOS handles them)")

        let src = TemperatureSource.aggregate(.cpuAverage)
        var curvePlan = FanPlan(); curvePlan.shared = FanPresets.curve(.balanced).strategy
        let e5 = FanControlEngine(profile: Self.simProfile)
        let b = curvePlan.shared
        if case .curve(let input, _, _, _, _, _) = b {
            _ = e5.tick(now: t0, temperatures: [input: 88], safetyTempC: 80, rawHottestC: 85, pressure: .nominal, plan: curvePlan)
            let lost = e5.tick(now: t0 + 1, temperatures: [:], safetyTempC: 80, rawHottestC: 85, pressure: .nominal, plan: curvePlan)
            if case .rpm(let r) = lost[0] ?? .system { check(r >= Self.simProfile.fans[0].rpm(forPercent: 50), "curve input lost -> hold current speed, ≥ 50 % (\(Int(r)) rpm)") }
            else { check(false, "curve input lost must hold") }
        }
        _ = src

        var guardPlan = FanPlan(); guardPlan.shared = .fixedPercent(20); guardPlan.thermalGuard.enabled = true
        let e6 = FanControlEngine(profile: Self.simProfile)
        var g: [Int: FanCommand] = [:]
        for s in 0...5 { g = e6.tick(now: t0 + Double(s), temperatures: [:], safetyTempC: 70, rawHottestC: 75, pressure: .moderate, plan: guardPlan) }
        check(e6.thermalGuardActive && g[0] == .rpm(Self.simProfile.fans[0].rpm(forPercent: 70).rounded()), "guard: moderate pressure for 5 s -> 70 % floor (\(g[0] ?? .system))")
        g = e6.tick(now: t0 + 6, temperatures: [:], safetyTempC: 70, rawHottestC: 75, pressure: .heavy, plan: guardPlan)
        check(g[0] == .rpm(5777), "guard: heavy pressure -> 100 %")
        for s in 7...36 { g = e6.tick(now: t0 + Double(s), temperatures: [:], safetyTempC: 70, rawHottestC: 75, pressure: .nominal, plan: guardPlan) }
        let rel = e6.tick(now: t0 + 37, temperatures: [:], safetyTempC: 70, rawHottestC: 75, pressure: .nominal, plan: guardPlan)
        check(!e6.thermalGuardActive && rel[0] == .rpm(2235), "guard: released after 30 s at nominal -> 20 % again")
        let e6b = FanControlEngine(profile: Self.simProfile)
        var sysGuard = FanPlan(); sysGuard.thermalGuard.enabled = true
        var sg: [Int: FanCommand] = [:]
        for s in 0...6 { sg = e6b.tick(now: t0 + Double(s), temperatures: [:], safetyTempC: 70, rawHottestC: 75, pressure: .heavy, plan: sysGuard) }
        check(sg[0] == .system, "guard never takes control in System mode by default")
        sysGuard.thermalGuard.applyInSystemMode = true
        sg = e6b.tick(now: t0 + 7, temperatures: [:], safetyTempC: 70, rawHottestC: 75, pressure: .heavy, plan: sysGuard)
        check(sg[0] == .system, "applyInSystemMode is ignored: Auto stays macOS's at heavy pressure")
        sg = e6b.tick(now: t0 + 8, temperatures: [:], safetyTempC: 110, rawHottestC: 112, pressure: .heavy, plan: sysGuard)
        check(sg[0] == .system, "the safety latch never takes a fan from Auto either")
        // Curve released below its first point (fans with macOS), then the raw die spikes: straight to maximum.
        var spikeCfg = FanUserConfig(); spikeCfg.mode = .curve
        let spikePlan = FanPlanBuilder.plan(config: spikeCfg, power: .ac, profile: Self.simProfile)
        let spikeInputs: [TemperatureSource: Double] = Dictionary(uniqueKeysWithValues: spikePlan.referencedSources.map { ($0, 50.0) })
        let eSpike = FanControlEngine(profile: Self.simProfile)
        let spikeBelow = eSpike.tick(now: t0, temperatures: spikeInputs, safetyTempC: 50, rawHottestC: 55, pressure: .nominal, plan: spikePlan)
        check(spikeBelow[0] == FanCommand.system && spikeBelow[1] == FanCommand.system, "curve below its first point leaves the fans to macOS")
        let spikeHot = eSpike.tick(now: t0 + 1, temperatures: spikeInputs, safetyTempC: 50, rawHottestC: 110, pressure: .nominal, plan: spikePlan)
        check(spikeHot[0] == FanCommand.rpm(5777) && spikeHot[1] == FanCommand.rpm(5777),
              "safety latch in Curve mode: both fans straight to maximum in one tick, even below the curve")
        // Fan stop below the first point (Apple Silicon): 0 rpm when cool, back at the first point, stopped again
        // after the slow-down hold, and the safety latch lifts a stopped fan straight to maximum.
        var stopCurve = FanPresets.curve(.balanced); stopCurve.below = .stop          // 70→0 … 95→100, hysteresis 3
        var stopPlan = FanPlan(); stopPlan.shared = stopCurve.strategy
        let eStop = FanControlEngine(profile: Self.simProfile)
        func stopTick(_ s: Double, _ c: Double, raw: Double = 60) -> [Int: FanCommand] {
            eStop.tick(now: t0 + s, temperatures: [stopCurve.input: c], safetyTempC: 60, rawHottestC: raw, pressure: .nominal, plan: stopPlan)
        }
        var sc = stopTick(0, 60)
        check(sc[0] == FanCommand.rpm(0) && sc[1] == FanCommand.rpm(0), "stop below the first point: both fans 0 rpm at 60 °C")
        for s in 1...10 { sc = stopTick(Double(s), 76) }
        if case .rpm(let r)? = sc[0] { check(r >= 1350, "restarted at the first point: \(Int(r)) rpm at 76 °C") }
        else { check(false, "restarted at the first point") }
        var stoppedAt: Int?
        for s in 11...400 { sc = stopTick(Double(s), 60); if sc[0] == FanCommand.rpm(0) { stoppedAt = s; break } }
        check(stoppedAt != nil, "stopped again \((stoppedAt ?? 0) - 10) s after cooling to 60 °C (hold + slow-down)")
        sc = stopTick(Double((stoppedAt ?? 400) + 1), 60, raw: 110)
        check(sc[0] == FanCommand.rpm(5777) && sc[1] == FanCommand.rpm(5777), "safety latch lifts stopped fans straight to maximum")

        var dbPlan = FanPlan(); dbPlan.shared = .fixedPercent(40)
        let e7 = FanControlEngine(profile: Self.simProfile)
        _ = e7.tick(now: t0, temperatures: [:], safetyTempC: 60, rawHottestC: 60, pressure: .nominal, plan: dbPlan)
        dbPlan.shared = .fixedPercent(40.5)                     // +22 rpm: inside the 50 rpm deadband
        let d1 = e7.tick(now: t0 + 1, temperatures: [:], safetyTempC: 60, rawHottestC: 60, pressure: .nominal, plan: dbPlan)
        var d2: [Int: FanCommand] = [:]
        for s in 2...6 { d2 = e7.tick(now: t0 + Double(s), temperatures: [:], safetyTempC: 60, rawHottestC: 60, pressure: .nominal, plan: dbPlan) }
        check(d1[0] == .rpm(3121) && d2[0] == .rpm(3143), "deadband: a 22 rpm change is sent only after 5 s of stability (\(d1[0] ?? .system) -> \(d2[0] ?? .system))")

        // Hysteresis band of a releasing curve: engage at the first point, release below first − hysteresis.
        let balanced = FanPresets.curve(.balanced)
        var hp = FanPlan(); hp.shared = balanced.strategy
        let e8 = FanControlEngine(profile: Self.simProfile)
        var engagements = 0
        var wasSystem = true
        let first = balanced.points[0].celsius
        for s in 0..<120 {
            let temp = first + (s % 2 == 0 ? -1.5 : 0.6)              // hovering around the first point
            let out = e8.tick(now: t0 + Double(s), temperatures: [balanced.input: temp], safetyTempC: 70, rawHottestC: 75,
                              pressure: .nominal, plan: hp)
            let isSystem = out[0] == .system
            if wasSystem && !isSystem { engagements += 1 }
            wasSystem = isSystem
        }
        check(engagements <= 1, "input hovering ±1 °C around the first point engages at most once in 2 min (\(engagements))")
        let cool = e8.tick(now: t0 + 121, temperatures: [balanced.input: first - balanced.hysteresisC - 6], safetyTempC: 60,
                           rawHottestC: 60, pressure: .nominal, plan: hp)
        var released = cool[0] == .system
        for s in 122..<160 where !released {
            released = e8.tick(now: t0 + Double(s), temperatures: [balanced.input: first - balanced.hysteresisC - 6], safetyTempC: 60,
                               rawHottestC: 60, pressure: .nominal, plan: hp)[0] == .system
        }
        check(released, "released to System once the input is below first − hysteresis")

        print("\n=== resetState keeps the safety latch; gated inputs; stale EMAs ===")
        // Fixed 30 %: latched at 101 °C, then 97 °C (inside the 94…100 band). A mode re-selection / lost lease resets.
        var f30 = FanPlan(); f30.shared = .fixedPercent(30)
        let e9 = FanControlEngine(profile: Self.simProfile)
        _ = e9.tick(now: t0, temperatures: [:], safetyTempC: 101, rawHottestC: 101, pressure: .nominal, plan: f30)
        for s in 1...4 { _ = e9.tick(now: t0 + Double(s), temperatures: [:], safetyTempC: 97, rawHottestC: 97, pressure: .nominal, plan: f30) }
        e9.resetState()
        var band: [Int: FanCommand] = [:]
        for s in 5...20 { band = e9.tick(now: t0 + Double(s), temperatures: [:], safetyTempC: 97, rawHottestC: 97, pressure: .nominal, plan: f30) }
        check(e9.safetyLatched && band[0] == .rpm(5777), "reset at 97 °C (latched at 101): still 100 % (\(band[0] ?? .system))")
        var cooled: [Int: FanCommand] = [:]
        for s in 21...60 { cooled = e9.tick(now: t0 + Double(s), temperatures: [:], safetyTempC: 85, rawHottestC: 85, pressure: .nominal, plan: f30) }
        check(!e9.safetyLatched && cooled[0] == .rpm(2678), "released below 94 °C -> back to 30 % (\(cooled[0] ?? .system))")
        let e9b = FanControlEngine(profile: Self.simProfile)
        _ = e9b.tick(now: t0, temperatures: [:], safetyTempC: 70, rawHottestC: 106, pressure: .nominal, plan: f30)
        e9b.resetState()
        let early = e9b.tick(now: t0 + 2, temperatures: [:], safetyTempC: 70, rawHottestC: 80, pressure: .nominal, plan: f30)
        check(e9b.safetyLatched && early[0] == .rpm(5777), "reset 2 s after a raw 106 °C spike: the 10 s minimum latch still holds")
        let e9c = FanControlEngine(profile: Self.simProfile)
        _ = e9c.tick(now: t0, temperatures: [:], safetyTempC: 101, rawHottestC: 101, pressure: .nominal, plan: f30)
        let woke = e9c.tick(now: t0 + 3600, temperatures: [:], safetyTempC: 60, rawHottestC: 62, pressure: .nominal, plan: f30)
        check(!e9c.safetyLatched && woke[0] == .rpm(2678), "after a 1 h gap (sleep) the latch re-evaluates from the fresh 60 °C")

        // Performance-like curve (no release) driven by one P-cluster die that power-gates at idle.
        let die = TemperatureSource.sensor(.smc("Tp0D"))
        var perf = FanPlan()
        perf.shared = .curve(sensor: die, points: [CurvePoint(50, 25), CurvePoint(82, 100)], hysteresisC: 2,
                             below: .minimum, smoothing: Smoothing(riseTau: 1, fallTau: 8), slew: Slew(up: 50, down: 3, hold: 20))
        let e10 = FanControlEngine(profile: Self.simProfile)
        var idle: [Int: FanCommand] = [:]
        for s in 0..<10 { idle = e10.tick(now: t0 + Double(s), temperatures: [die: 45], safetyTempC: 60, rawHottestC: 62, pressure: .nominal, plan: perf) }
        let gatedOut = e10.tick(now: t0 + 10, temperatures: [:], gated: [die], safetyTempC: 60, rawHottestC: 62, pressure: .nominal, plan: perf)
        check(idle[0] == .rpm(2457) && gatedOut[0] == idle[0], "gated input keeps its last value: \(idle[0] ?? .system) -> \(gatedOut[0] ?? .system), not ≥ 50 %")
        check(e10.smoothedTemperature(die).map { abs($0 - 45) < 0.5 } == true, "gated: the operating point stays at the last reading")
        let lostOut = e10.tick(now: t0 + 11, temperatures: [:], safetyTempC: 60, rawHottestC: 62, pressure: .nominal, plan: perf)
        check(lostOut[0] == .rpm(3564), "a truly missing input still gets the fail-safe ≥ 50 % (\(lostOut[0] ?? .system))")

        // Balanced (socHottest 2/12 s) -> Cool (socHottest 1.5/10 s): one input, two EMA keys. The operating point
        // must follow the curve in use, never the abandoned EMA.
        let bal = FanPresets.curve(.balanced), coolCurve = FanPresets.curve(.cool)
        var pb = FanPlan(); pb.shared = bal.strategy
        var pc = FanPlan(); pc.shared = coolCurve.strategy
        let e11 = FanControlEngine(profile: Self.simProfile)
        for s in 0..<5 { _ = e11.tick(now: t0 + Double(s), temperatures: [bal.input: 70], safetyTempC: 70, rawHottestC: 72, pressure: .nominal, plan: pb) }
        for s in 5..<40 { _ = e11.tick(now: t0 + Double(s), temperatures: [coolCurve.input: 80], safetyTempC: 70, rawHottestC: 72, pressure: .nominal, plan: pc) }
        let op = e11.smoothedTemperature(coolCurve.input)
        check(bal.input == coolCurve.input && op.map { abs($0 - 80) < 0.5 } == true,
              "after a preset switch the operating point follows the new curve (\(op.map { String(format: "%.1f", $0) } ?? "—") °C, input 80)")
    }

    // MARK: Plan builder and presets

    func planAndPresetScenarios() {
        print("\n=== FanPlanBuilder (SPEC §2.9.2 table) ===")
        var cfg = FanUserConfig()
        cfg.mode = .system; check(FanPlanBuilder.plan(config: cfg, power: .ac, profile: Self.simProfile).shared == .system, "System -> shared .system")
        cfg.mode = .max; check(FanPlanBuilder.plan(config: cfg, power: .ac, profile: Self.simProfile).shared == .fixedPercent(100), "Max -> fixedPercent(100)")
        cfg.mode = .fixed; cfg.fixedPercent = 35
        check(FanPlanBuilder.plan(config: cfg, power: .ac, profile: Self.simProfile).shared == .fixedPercent(35), "Fixed linked -> shared fixedPercent(35)")
        cfg.linked = false; cfg.fixedPercentPerFan = [1: 70]
        let unlinked = FanPlanBuilder.plan(config: cfg, power: .ac, profile: Self.simProfile)
        check(!unlinked.linked && unlinked.perFan[0] == .fixedPercent(35) && unlinked.perFan[1] == .fixedPercent(70), "Fixed unlinked -> perFan [0: 35, 1: 70]")
        cfg = FanUserConfig(); cfg.mode = .curve; cfg.curveAC = FanPresets.curve(.quiet); cfg.curveBattery = FanPresets.curve(.cool)
        check(FanPlanBuilder.plan(config: cfg, power: .ac, profile: Self.simProfile).shared == FanPresets.curve(.quiet).strategy, "Curve on AC -> curveAC")
        check(FanPlanBuilder.plan(config: cfg, power: .battery, profile: Self.simProfile).shared == FanPresets.curve(.cool).strategy, "Curve on battery -> curveBattery")
        cfg.curveBattery = nil
        check(FanPlanBuilder.plan(config: cfg, power: .battery, profile: Self.simProfile).shared == FanPresets.curve(.quiet).strategy, "Curve on battery without curveBattery -> curveAC")
        cfg.thermalGuard.enabled = true
        check(FanPlanBuilder.plan(config: cfg, power: .ac, profile: .none).shared == .system &&
              FanPlanBuilder.plan(config: cfg, power: .ac, profile: Self.simProfile).thermalGuard.enabled, "not controllable -> System; guard/safety copied")

        print("\n=== Presets (M4 Max tuning) on a synthetic day: idle 64 °C -> load 80 °C -> hot 92 °C -> idle ===")
        var day: [Double] = Array(repeating: 64, count: 30)
        for i in 0..<16 { day.append(64 + Double(i)) }
        day += Array(repeating: 80, count: 30)
        for i in 0..<12 { day.append(80 + Double(i)) }
        day += Array(repeating: 92, count: 20)
        day += Array(repeating: 64, count: 150)
        for id in FanPresetID.allCases {
            let curve = FanPresets.curve(id)
            let pts = curve.points.map { "\(Int($0.celsius))→\(Int($0.percent))" }.joined(separator: " ")
            let e = FanControlEngine(profile: Self.simProfile)
            var plan = FanPlan(); plan.shared = curve.strategy
            var samples: [(Int, FanCommand)] = []
            for (t, temp) in day.enumerated() {
                var temps: [TemperatureSource: Double] = [:]
                for s in plan.referencedSources { temps[s] = temp + (s == .aggregate(.safetyTop4) ? 12 : 0) }
                let out = e.tick(now: Date(timeIntervalSince1970: Double(t)), temperatures: temps, safetyTempC: temp + 12,
                                 rawHottestC: temp + 18, pressure: .nominal, plan: plan)
                samples.append((t, out[0] ?? .system))
            }
            func at(_ t: Int) -> String { "\(samples[t].1)" }
            print(String(format: "  %@ input %@ %@  hyst %.0f  ramp %.0f/%.0f s  hold %.0f s", pad(id.rawValue, 12) as NSString,
                         pad(describe(curve.input), 12) as NSString, pts as NSString, curve.hysteresisC,
                         100 / curve.slew.upPercentPerSecond, 100 / curve.slew.downPercentPerSecond, curve.slew.downHoldSeconds))
            print("               idle \(at(29)) | load \(at(75)) | hot \(at(107)) | idle+60 s \(at(167)) | idle+150 s \(at(day.count - 1))")
            switch id {
            case .quiet, .balanced: check(samples[29].1 == .system, "\(id.rawValue): System (fans may stop) at a 64 °C idle")
            case .cool, .performance: check(samples[29].1 != .system, "\(id.rawValue): keeps the fans spinning at idle")
            }
        }
    }
}

/// Left-aligned (or right-aligned) fixed-width column (String(format:) does not pad %@).
func pad(_ s: String, _ n: Int, left: Bool = false) -> String {
    guard s.count < n else { return s }
    let fill = String(repeating: " ", count: n - s.count)
    return left ? fill + s : s + fill
}

/// "cpuAverage", "smc:Tp01".
func describe(_ s: TemperatureSource) -> String {
    switch s { case .aggregate(let k): k.rawValue; case .sensor(let id): id.description }
}

/// Compact SafetyVerdict text.
func text(_ v: SafetyVerdict) -> String {
    switch v {
    case .normal(let h): return "normal(hottest \(h.map { String(format: "%.1f", $0) } ?? "—"))"
    case let .override(h, m): return String(format: "OVERRIDE(hottest %.1f, top-4 %.1f)", h, m)
    case .sensorFailure: return "sensorFailure"
    }
}
