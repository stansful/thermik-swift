// Probe+Fans.swift — `thermik-probe fans profile|snapshot|inspect|dryrun|sim`.
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
        default: printFansUsage()
        }
    }

    private static func printFansUsage() {
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
        printFanDescriptors(p)
    }

    private static func printFanDescriptors(_ profile: FanHardwareProfile) {
        for f in profile.fans {
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
        await printSnapshots(smc, profile: p, count: count)
        reportForeignController(smc, profile: p)
    }

    private static func printSnapshots(_ smc: SMCConnection, profile: FanHardwareProfile, count: Int) async {
        for n in 0..<count {
            if n > 0 { try? await Task.sleep(for: .seconds(1)) }
            let st = FanReader.snapshot(smc, profile: profile)
            printFanSnapshot(st, profile: profile, prefix: count > 1 ? "[\(n + 1)/\(count)] " : "")
        }
    }

    private static func printFanSnapshot(_ st: FanControlState, profile: FanHardwareProfile, prefix: String) {
        var head = "Ftst=\(st.ftst.map(String.init) ?? "—")"
        if let fs = st.forceBits { head += String(format: "  FS!=0x%04x", fs) }
        print(prefix + head)
        printSnapshotFans(st, profile: profile)
        if st.anyManual { print("  forcing: \(st.forcingSignals.joined(separator: ", "))") }
    }

    private static func printSnapshotFans(_ st: FanControlState, profile: FanHardwareProfile) {
        for f in st.fans {
            let name = profile.fan(f.index)?.name ?? "fan"
            print(String(format: "  fan %d %@ Ac %5.0f rpm  Tg %5.0f rpm  Md %@  Dc %@%@", f.index, pad(name, 10) as NSString,
                         f.actualRPM, f.targetRPM, (f.mode?.description ?? "—") as NSString,
                         (f.dutyCycle.map { String(format: "%.3f", $0) } ?? "—") as NSString,
                         (f.isOff ? "  (off — macOS stopped it)" : "") as NSString))
        }
    }

    /// Decision = SMC state, never the client's self-report; a Thermik helper may be the owner of the forcing.
    private static func reportForeignController(_ smc: SMCConnection, profile: FanHardwareProfile) {
        let st = FanReader.snapshot(smc, profile: profile)
        guard st.anyManual else { print("no forcing: macOS controls the fans"); return }
        let clients = SMCClientInspector.classifiedClients()
        if clients.contains(where: { $0.kind == .thermikHelper }) {
            print("forcing seen while Thermik's helper holds an SMC connection: ask the helper (getState) whether it is Thermik")
        }
        printSuspectedController()
    }

    private static func printSuspectedController() {
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
        inspectSMCForcing()
    }

    private static func inspectSMCForcing() {
        guard let smc = openSMC() else { return }
        let st = FanReader.snapshot(smc, profile: FanHardwareProfile.discover(smc))
        print("SMC forcing signals: \(st.forcingSignals.isEmpty ? "none" : st.forcingSignals.joined(separator: ", "))")
    }

    // MARK: Dry run

    private typealias DryRunColumn = (name: String, config: FanUserConfig)
    private typealias DryRunStats = [AggregateKind: (min: Double, max: Double)]

    static func dryRun(_ args: [String]) async {
        let options = dryRunOptions(args)
        guard let source = await LiveTemperatures.make() else { return }
        guard source.fanProfile.isControllable else { print("fans not controllable (scheme \(source.fanProfile.scheme)): nothing to dry-run"); return }
        let columns = dryRunColumns()
        let engines = columns.map { _ in FanControlEngine(profile: source.fanProfile) }
        printDryRunHeader(columns, seconds: options.seconds, source: source)
        let load = startLoad(threads: options.loadThreads, seconds: options.seconds)
        defer { load?.stop() }
        await runDryRows(source, columns: columns, engines: engines, seconds: options.seconds)
        printLiveFans(source)
    }

    private static func dryRunOptions(_ args: [String]) -> (seconds: Int, loadThreads: Int) {
        var options = (seconds: 30, loadThreads: 0, nextIndex: 0)
        while options.nextIndex < args.count {
            options = nextDryRunOptions(args, index: options.nextIndex, current: options)
        }
        return (max(5, min(options.seconds, 60)), options.loadThreads)   // load tests: ≤ 60 s in total
    }

    private static func nextDryRunOptions(_ args: [String], index: Int,
                                          current: (seconds: Int, loadThreads: Int, nextIndex: Int))
        -> (seconds: Int, loadThreads: Int, nextIndex: Int) {
        if let threads = loadThreads(args, index: index) {
            return (current.seconds, threads, index + 2)
        }
        if let seconds = Int(args[index]) {
            return (seconds, current.loadThreads, index + 1)
        }
        return (current.seconds, current.loadThreads, index + 1)
    }

    private static func loadThreads(_ args: [String], index: Int) -> Int? {
        guard args[index] == "--load", index + 1 < args.count else { return nil }
        return max(0, min(Int(args[index + 1]) ?? 0, 64))
    }

    /// One engine per column; plans come from the real FanPlanBuilder.
    private static func dryRunColumns() -> [DryRunColumn] {
        var columns: [DryRunColumn] = FanPresetID.allCases.map { (name: $0.rawValue, config: curveConfig($0)) }
        columns += [("fixed40", fixedConfig()), ("max", maxConfig())]
        return columns
    }

    private static func curveConfig(_ id: FanPresetID) -> FanUserConfig {
        var config = FanUserConfig()
        config.mode = .curve
        config.curveAC = FanPresets.curve(id)
        return config
    }

    private static func fixedConfig() -> FanUserConfig {
        var config = FanUserConfig()
        config.mode = .fixed
        config.fixedPercent = 40
        return config
    }

    private static func maxConfig() -> FanUserConfig {
        var config = FanUserConfig()
        config.mode = .max
        return config
    }

    private static func printDryRunHeader(_ columns: [DryRunColumn], seconds: Int, source: LiveTemperatures) {
        print("dry run \(seconds) s @ 1 Hz, temperatures from \(source.origin); commands are PRINTED, NEVER SENT")
        print("fans: " + source.fanProfile.fans.map { "\($0.index) \(Int($0.minRPM))…\(Int($0.maxRPM))" }.joined(separator: ", ") +
              "   scheme \(source.fanProfile.scheme)")
        var header = "  t  cpuAvg socHot  gpuAvg  top4  rawMax press |"
        for c in columns { header += " " + c.name.padding(toLength: 11, withPad: " ", startingAt: 0) + "|" }
        print(header)
    }

    private static func startLoad(threads: Int, seconds: Int) -> BusyLoad? {
        guard threads > 0 else { return nil }
        let load = BusyLoad(threads: threads)
        print("load: \(load.threads) busy threads for \(seconds) s (stopped by the probe)")
        return load
    }

    private static func runDryRows(_ source: LiveTemperatures, columns: [DryRunColumn],
                                   engines: [FanControlEngine], seconds: Int) async {
        var stats: DryRunStats = [:]
        await runDryRowLoop(source, columns: columns, engines: engines, seconds: seconds, stats: &stats)
        printRanges(stats)
    }

    private static func runDryRowLoop(_ source: LiveTemperatures, columns: [DryRunColumn], engines: [FanControlEngine],
                                      seconds: Int, stats: inout DryRunStats) async {
        let clock = ContinuousClock()
        var next = clock.now
        for t in 0..<seconds {
            let sample = await source.read()
            recordRanges(sample, stats: &stats)
            print(dryRunLine(t, sample: sample, columns: columns, engines: engines, profile: source.fanProfile))
            next = next.advanced(by: .seconds(1))
            try? await clock.sleep(until: next, tolerance: .milliseconds(50))
        }
    }

    private static func recordRanges(_ sample: TemperatureSample, stats: inout DryRunStats) {
        for (kind, value) in sample.smoothed.values {
            let current = stats[kind] ?? (value, value)
            stats[kind] = (min(current.min, value), max(current.max, value))
        }
    }

    private static func dryRunLine(_ t: Int, sample: TemperatureSample, columns: [DryRunColumn],
                                   engines: [FanControlEngine], profile: FanHardwareProfile) -> String {
        var line = dryRunPrefix(t, sample: sample)
        for (j, column) in columns.enumerated() {
            let plan = FanPlanBuilder.plan(config: column.config, power: .ac, profile: profile)
            let temps = referencedTemperatures(plan: plan, sample: sample)
            let out = engines[j].tick(now: sample.date, temperatures: temps, safetyTempC: sample.smoothed[.safetyTop4],
                                      rawHottestC: sample.raw[.rawHottestDie], pressure: sample.pressure, plan: plan)
            line += " " + commandText(out, profile).padding(toLength: 11, withPad: " ", startingAt: 0) + "|"
        }
        return line
    }

    private static func dryRunPrefix(_ t: Int, sample: TemperatureSample) -> String {
        String(format: "%3d ", t) + [sample.smoothed[.cpuAverage], sample.smoothed[.socHottest], sample.smoothed[.gpuAverage],
                                      sample.smoothed[.safetyTop4], sample.raw[.rawHottestDie]].map { pad(f($0), 6, left: true) }
            .joined(separator: " ") + " " + pad(sample.pressure.short, 5) + " |"
    }

    private static func referencedTemperatures(plan: FanPlan, sample: TemperatureSample) -> [TemperatureSource: Double] {
        var temperatures: [TemperatureSource: Double] = [:]
        for source in plan.referencedSources {
            if let value = sample.value(source) { temperatures[source] = value }
        }
        return temperatures
    }

    private static func printRanges(_ stats: DryRunStats) {
        print("ranges (smoothed °C): " + [AggregateKind.cpuAverage, .cpuHottest, .gpuAverage, .socHottest, .safetyTop4]
            .compactMap { k in stats[k].map { "\(k.rawValue) \(String(format: "%.1f…%.1f", $0.min, $0.max))" } }
            .joined(separator: "  "))
    }

    private static func printLiveFans(_ source: LiveTemperatures) {
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

/// Live temperatures for the dry run: `SensorSampler` + `SensorAggregator` (read-only).
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
        let frame = await sampler.sample(SampleRequest(sensorIDs: inv.sensors.map(\.id), components: []))
        let aggregates = aggregateValues(frame.values, inventory: inv, now: now)
        let state = pressureState()
        return TemperatureSample(date: now, smoothed: aggregates.smoothed, raw: aggregates.raw, sensors: frame.values,
                                 pressure: ThermalPressure(rawValue: state) ?? .nominal)
    }

    /// SensorStore-like smoothing: τ 2.8 s, 1.5 s for the "hottest" kinds (SPEC §2.5.6).
    private func aggregateValues(_ values: [SensorID: Double], inventory: SensorInventory, now: Date)
        -> (smoothed: AggregateValues, raw: AggregateValues) {
        let raw = SensorAggregator(inventory: inventory).aggregates(values, visible: Set(inventory.sensors.filter(\.isVisibleByDefault).map(\.id)))
        let dt = lastDate.map { max(now.timeIntervalSince($0), 0.1) } ?? 1
        lastDate = now
        var smoothed = AggregateValues()
        for (kind, value) in raw.values {
            let smoothedValue = self.smoothedValue(kind, value: value, dt: dt)
            ema[kind] = smoothedValue
            smoothed.values[kind] = smoothedValue
        }
        return (smoothed, raw)
    }

    private func smoothedValue(_ kind: AggregateKind, value: Double, dt: Double) -> Double {
        let tau: Double = [.cpuHottest, .gpuHottest, .highestAll, .rawHottestDie].contains(kind) ? 1.5 : 2.8
        let previous = ema[kind]
        return previous.map { $0 + (1 - exp(-dt / tau)) * (value - $0) } ?? value
    }

    private func pressureState() -> UInt64 {
        var state: UInt64 = 0
        if pressureToken >= 0 { notify_get_state(pressureToken, &state) }
        return state
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
        transientDiscoveryScenario()
        persistentDiscoveryScenario()
        fanlessDiscoveryScenario()
    }

    private func discoveryProfile(_ generation: FakeSMC.Generation, _ failing: [FourCC: Int]) -> FanHardwareProfile {
        FanHardwareProfile.discover(FlakySMC(FakeSMC(generation, clock: SimulatedClock()), failing: failing),
                                    appleSilicon: generation.isAppleSilicon)
    }

    private func transientDiscoveryScenario() {
        let transient = discoveryProfile(.m4, ["F1Mx": 2, "FNum": 1, "Ftst": 1])
        check(transient.fans.count == 2 && transient.isComplete && transient.isControllable && transient.scheme.requiresAllOrNothing,
              "M4: FNum, Ftst and F1Mx fail once or twice -> retried: 2 fans, Ftst scheme, controllable")
    }

    private func persistentDiscoveryScenario() {
        let lost = discoveryProfile(.m4, ["F1Mx": -1])
        check(lost.fans.map(\.index) == [0] && lost.unreadableFans == [1] && !lost.isControllable,
              "M4: F1Mx never readable -> fan 1 unreadable, profile NOT controllable (all-or-nothing)")
        let plan = FanPlanBuilder.plan(config: { var c = FanUserConfig(); c.mode = .max; return c }(), power: .ac, profile: lost)
        check(plan.shared == .system, "incomplete Ftst profile: the plan stays System")
        let m5 = discoveryProfile(.m5, ["F1Mx": -1])
        check(m5.fans.map(\.index) == [0] && !m5.isComplete && m5.isControllable, "M5 (per-fan, no Ftst): fan 0 stays controllable")
    }

    private func fanlessDiscoveryScenario() {
        let fanless = discoveryProfile(.m4, ["FNum": -1])
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
        m4SequencerScenario()
        m4TimeoutScenario()
        m1DirectScenario()
        stoppedReleaseScenario()
        m1ReclaimsScenario()
        m5SequencerScenario()
        intelPreT2Scenario()
        intelT2Scenario()
        allowListScenario()
    }

    private func m4SequencerScenario() {
        run("M4: unlock via Ftst after the 3.5 s fake delay, clamp high/low, release last fan clears Ftst", .m4, m4SequencerActions)
    }

    private func m4SequencerActions(_ seq: FanWriteSequencer, _ smc: FakeSMC, _ clock: SimulatedClock) throws {
        try checkM4Targets(seq, smc: smc, clock: clock)
        try checkM4Releases(seq, smc: smc)
    }

    private func checkM4Targets(_ seq: FanWriteSequencer, smc: FakeSMC, clock: SimulatedClock) throws {
        let a0 = try seq.setTarget(0, rpm: 99_999)
        let unlockedAt = clock.now().timeIntervalSince1970
        let a1 = try seq.setTarget(1, rpm: 10)
        print("   applied fan0 = \(a0), fan1 = \(a1)")
        check(a0 == 5777, "99999 rpm clamped to Mx 5777")
        check(a1 == 1350, "10 rpm clamped to Mn 1350")
        check(unlockedAt >= 3.5 && unlockedAt <= 4.0, String(format: "fan 0 manual after the unlock (t=%.2f s)", unlockedAt))
        check(smc.writeLog.contains { $0.contains("F0Md=01 -> 0x82") }, "direct mode write refused with 0x82 while mode 3")
        check(smc.bytes("F0Tg") == SMCCodec.encodeFloat32LE(5777), "F0Tg = 0088b445 (5777.0 flt LE)")
    }

    private func checkM4Releases(_ seq: FanWriteSequencer, smc: FakeSMC) throws {
        try seq.release(0)
        check(smc.bytes(FanHardwareProfile.ftstKey) == [1], "Ftst stays 1 while fan 1 is still owned")
        try seq.release(1)
        check(smc.writeLog.last?.hasSuffix("Ftst=00") == true, "releasing the last fan writes Ftst=0")
        check(mode(smc, "F0Md") == 3 && mode(smc, "F1Md") == 3, "macOS reclaims both fans (mode 3)")
    }

    private func m4TimeoutScenario() {
        run("M4 under load: thermalmonitord never yields -> timeout after 12 s, Ftst cleaned up", .m4Refusing, m4TimeoutActions)
    }

    private func m4TimeoutActions(_ seq: FanWriteSequencer, _ smc: FakeSMC, _ clock: SimulatedClock) throws {
        do {
            _ = try seq.setTarget(0, rpm: 3000)
            check(false, "unlock must time out")
        } catch let error as FanWriteError {
            print("   expected error: \(error)")
            checkUnlockTimeout(error, clock: clock)
            check(error.helperErrorCode == .unlockTimeout, "maps to HelperErrorCode.unlockTimeout (10)")
        }
        check(smc.bytes(FanHardwareProfile.ftstKey) == [0] && !seq.ftstSetByUs, "Ftst cleared, nothing owned")
    }

    private func checkUnlockTimeout(_ error: FanWriteError, clock: SimulatedClock) {
        if case .unlockTimeout = error { check(true, "unlockTimeout after \(Int(clock.now().timeIntervalSince1970)) s") }
        else { check(false, "unlockTimeout") }
    }

    private func m1DirectScenario() {
        run("M1: direct write sticks (Ftst present but unused)", .m1Direct, m1DirectActions)
    }

    private func m1DirectActions(_ seq: FanWriteSequencer, _ smc: FakeSMC, _ clock: SimulatedClock) throws {
        _ = try seq.setTarget(0, rpm: 3000)
        check(!smc.writeLog.contains { $0.contains("Ftst") }, "no Ftst write")
        _ = seq.releaseAll(reason: "test")
        check(mode(smc, "F0Md") == 0, "fan 0 back to mode 0")
    }

    private func stoppedReleaseScenario() {
        run("M4 Max: a stopped fan refuses F%dMd=0 (0x82) -> spun up to Mn first, then handed back", .m1Direct, stoppedReleaseActions)
    }

    private func stoppedReleaseActions(_ seq: FanWriteSequencer, _ smc: FakeSMC, _ clock: SimulatedClock) throws {
        try stopAndRelease(seq, smc: smc, clock: clock)
        checkStoppedReleaseLog(smc)
    }

    private func stopAndRelease(_ seq: FanWriteSequencer, smc: FakeSMC, clock: SimulatedClock) throws {
        smc.refusesReleaseWhileStopped = true
        smc.spinUpDelay = 1.2
        _ = try seq.setTarget(0, rpm: 0)
        _ = try seq.setTarget(1, rpm: 0)
        check(seq.appliedRPM[0] == 0 && seq.appliedRPM[1] == 0, "rpm 0 stops both fans")
        let start = clock.now()
        let failures = seq.releaseAll(reason: "quit while stopped")
        let took = clock.now().timeIntervalSince(start)
        print(String(format: "   failures: %@, release took %.2f s", failures.description, took))
        checkStoppedReleaseResult(seq, smc: smc, failures: failures, took: took)
    }

    private func checkStoppedReleaseResult(_ seq: FanWriteSequencer, smc: FakeSMC, failures: [String], took: Double) {
        check(failures.isEmpty && mode(smc, "F0Md") == 0 && mode(smc, "F1Md") == 0 && seq.ownedFans.isEmpty,
              "both stopped fans back to System")
        check(took < 2, String(format: "both fans spin up together: %.2f s for a 1.2 s spin-up, not twice that", took))
    }

    private func checkStoppedReleaseLog(_ smc: FakeSMC) {
        let log = smc.writeLog
        check(log.contains { $0.contains("F0Md=00 -> 0x82") }, "F0Md=0 refused while fan 0 still stood")
        let tg = log.lastIndex { $0.contains("F0Tg=") }
        let md = log.lastIndex { $0.hasSuffix("F0Md=00") }
        check(tg != nil && md != nil && tg! < md!, "F0Tg set to the minimum before the accepted F0Md=0")
    }

    private func m1ReclaimsScenario() {
        run("M1 variant: direct write reclaimed -> escalate to Ftst", .m1Reclaims, m1ReclaimsActions)
    }

    private func m1ReclaimsActions(_ seq: FanWriteSequencer, _ smc: FakeSMC, _ clock: SimulatedClock) throws {
        _ = try seq.setTarget(0, rpm: 3000)
        check(smc.writeLog.contains { $0.contains("Ftst=01") }, "escalated to the Ftst unlock")
        _ = seq.releaseAll(reason: "test")
        check(smc.bytes(FanHardwareProfile.ftstKey) == [0], "Ftst cleared on release")
    }

    private func m5SequencerScenario() {
        run("M5: lowercase F%dmd, no Ftst, direct", .m5, m5SequencerActions)
    }

    private func m5SequencerActions(_ seq: FanWriteSequencer, _ smc: FakeSMC, _ clock: SimulatedClock) throws {
        _ = try seq.setTarget(0, rpm: 4000)
        _ = try seq.setTarget(1, rpm: 4000)
        check(smc.writeLog.first?.contains("F0md=01") == true, "lowercase mode key written")
        check(seq.allowList.contains("F0md") && !seq.allowList.contains("F0Md") && !seq.allowList.contains("Ftst"),
              "allow-list = lowercase mode keys, no Ftst")
        _ = seq.releaseAll(reason: "lease expired")
        check(mode(smc, "F0md") == 0 && mode(smc, "F1md") == 0, "both fans released")
    }

    private func intelPreT2Scenario() {
        run("Intel pre-T2: FS! bitmask + fpe2", .intelPreT2, intelPreT2Actions)
    }

    private func intelPreT2Actions(_ seq: FanWriteSequencer, _ smc: FakeSMC, _ clock: SimulatedClock) throws {
        _ = try seq.setTarget(1, rpm: 3500)
        let tg = smc.bytes("F1Tg") ?? []
        print("   F1Tg bytes: \(tg.map { String(format: "%02x", $0) }.joined())")
        check(tg == [0x36, 0xb0], "3500 rpm -> fpe2 36b0 (big-endian 14.2)")
        check(smc.bytes(FanHardwareProfile.forceBitsKey) == [0, 2], "FS! bit 1 set")
        _ = seq.releaseAll(reason: "sigterm")
        check(smc.bytes(FanHardwareProfile.forceBitsKey) == [0, 0], "FS! cleared")
    }

    private func intelT2Scenario() {
        run("Intel T2: F%dMd + flt", .intelT2, intelT2Actions)
    }

    private func intelT2Actions(_ seq: FanWriteSequencer, _ smc: FakeSMC, _ clock: SimulatedClock) throws {
        _ = try seq.setTarget(0, rpm: 2500)
        check(smc.bytes("F0Tg") == SMCCodec.encodeFloat32LE(2500), "flt target 2500")
        try seq.release(0)
        check(mode(smc, "F0Md") == 0, "fan 0 back to mode 0")
    }

    private func allowListScenario() {
        run("Allow-list and argument checks", .m4, allowListActions)
    }

    private func allowListActions(_ seq: FanWriteSequencer, _ smc: FakeSMC, _ clock: SimulatedClock) throws {
        checkInvalidFanIndex(seq)
        checkNaNRefused(seq)
        checkNegativeRefused(seq)
        check(seq.allowList == ["F0Md", "F1Md", "F0Tg", "F1Tg", "Ftst"], "allow-list = {F0Md, F1Md, F0Tg, F1Tg, Ftst}")
        check(!seq.allowList.contains("FOFC"), "writable unknown key FOFC is not allow-listed")
        check(smc.writeLog.isEmpty, "no write happened")
    }

    private func checkInvalidFanIndex(_ seq: FanWriteSequencer) {
        do {
            try seq.ensureManual(7)
            check(false, "fan 7 must be refused")
        } catch {
            check("\(error)" == "no fan 7", "invalid fan index refused (\(error))")
        }
    }

    private func checkNaNRefused(_ seq: FanWriteSequencer) {
        do {
            _ = try seq.setTarget(0, rpm: .nan)
            check(false, "NaN must be refused")
        } catch {
            check(true, "NaN rpm refused (\(error))")
        }
    }

    private func checkNegativeRefused(_ seq: FanWriteSequencer) {
        do {
            _ = try seq.setTarget(0, rpm: -1)
            check(false, "negative must be refused")
        } catch {
            check(true, "negative rpm refused")
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
        startupRecoveryScenario()
        foreignControllerScenario()
        reclaimedFanScenario()
    }

    private func startupRecoveryScenario() {
        print("\n=== Startup recovery after SIGKILL (marker found: force release of the previous instance's state) ===")
        let clock = SimulatedClock()
        let smc = FakeSMC(.m4, clock: clock)
        preparePreviousControllerState(smc, clock: clock)
        checkStartupRecovery(smc, clock: clock)
    }

    /// A previous helper instance left Ftst=1 and fan 0 manual, written directly rather than through the sequencer.
    private func preparePreviousControllerState(_ smc: FakeSMC, clock: SimulatedClock) {
        try? smc.writeRaw(FanHardwareProfile.ftstKey, [1])
        clock.sleep(4)
        try? smc.writeRaw("F0Md", [1])
        try? smc.writeRaw("F0Tg", SMCCodec.encodeFloat32LE(1350))
        smc.appendLog("---- helper restarted ----")
    }

    private func checkStartupRecovery(_ smc: FakeSMC, clock: SimulatedClock) {
        let fresh = SMCFanController(device: smc, appleSilicon: true, clock: clock, log: { print("   log: \($0)") })
        fresh.markerPath = nil
        fresh.adoptPersistedState(ftstSetByUs: true)
        check(!fresh.foreignControlSuspected(), "own leftover state is not a foreign controller while recovering")
        let failures = fresh.forceRestoreAll(reason: "startupRecovery")
        print("   failures: \(failures)")
        printTrace(smc, profile: fresh.profile, owned: fresh.ownedFans, ftstSetByUs: fresh.ftstSetByUs)
        check(failures.isEmpty && smc.bytes(FanHardwareProfile.ftstKey) == [0] && mode(smc, "F0Md") == 3, "fans restored to System (mode 3, Ftst 0)")
    }

    private func foreignControllerScenario() {
        print("\n=== Foreign controller (I10): another app forces the fans ===")
        let clock = SimulatedClock()
        let (controller, smc) = makeController(.m4, clock: clock)
        check(!controller.foreignControlSuspected(), "idle M4 (mode 3, Ftst 0): not suspected")
        smc.simulateForeignController()
        print("   SMC: \(state(smc, controller.profile))")
        check(controller.foreignControlSuspected(), "Ftst=1 + modes=1 with no marker: suspected")
        checkMarkerAndSafety(controller)
    }

    private func checkMarkerAndSafety(_ controller: SMCFanController) {
        let marker = NSTemporaryDirectory() + "thermik-probe-marker-\(getpid())"
        FileManager.default.createFile(atPath: marker, contents: Data("{}".utf8))
        controller.markerPath = marker
        check(!controller.foreignControlSuspected(), "marker present (state may be Thermik's): not suspected")
        try? FileManager.default.removeItem(atPath: marker)
        controller.markerPath = nil
        check(controller.evaluateSafety() == .normal(hottestC: nil), "not controlling: the safety monitor does not read the SMC")
    }

    private func reclaimedFanScenario() {
        print("\n=== Reclaimed fan: re-assert throttled to once per 5 s ===")
        let clock = SimulatedClock()
        let (controller, smc) = makeController(.m4, clock: clock)
        prepareReclaimedFan(controller, smc: smc, clock: clock)
        checkReassertThrottle(controller)
        finishReclaimedFan(controller, smc: smc, clock: clock)
    }

    private func prepareReclaimedFan(_ controller: SMCFanController, smc: FakeSMC, clock: SimulatedClock) {
        _ = try? controller.setManual(0, targetRPM: 3000)
        _ = try? controller.setManual(1, targetRPM: 3000)
        print(String(format: "   both fans manual at t=%.2f s; states %@", clock.now().timeIntervalSince1970,
                     controller.fanStates().map { "\($0.index):\($0.modeRaw ?? -1)/\(Int($0.actualRPM))" }.joined(separator: " ")))
        smc.simulateReclaim(fan: 0)
        check(controller.reclaimedFans() == [0], "fan 0 reported as reclaimed")
    }

    private func checkReassertThrottle(_ controller: SMCFanController) {
        do {
            _ = try controller.setManual(0, targetRPM: 3000)
            check(false, "re-assert inside 5 s must be throttled")
        } catch let error as FanWriteError {
            if case .reclaimedTooSoon = error { check(true, "re-assert inside 5 s refused (\(error))") }
            else { check(false, "\(error)") }
        } catch {
            check(false, "\(error)")
        }
    }

    private func finishReclaimedFan(_ controller: SMCFanController, smc: FakeSMC, clock: SimulatedClock) {
        clock.advance(1.5)
        let applied = try? controller.setManual(0, targetRPM: 3000)
        check(applied == 3000 && controller.reclaimedFans().isEmpty, "re-asserted after 5 s")
        let failures = controller.restoreAll(reason: "test")
        check(failures.isEmpty && !controller.isControlling && mode(smc, "F0Md") == 3, "restoreAll: System again")
    }

    // MARK: ThermalSafetyMonitor (I8/I9)

    private final class SafetyRamp {
        let smc: FakeSMC
        let clock: SimulatedClock
        let live: [FourCC]
        var tick = 0

        init(smc: FakeSMC, clock: SimulatedClock, live: [FourCC]) {
            self.smc = smc
            self.clock = clock
            self.live = live
        }

        /// Live probes jitter like real ones (±0.1 °C per tick); Tp0X never changes.
        func step(_ base: Double, spread: Double) {
            tick += 1
            for (n, key) in live.enumerated() { smc.setTemperature(key, base + spread * Double(n) + (tick % 2 == 0 ? 0.1 : -0.1)) }
            clock.advance(1)
        }
    }

    func safetyScenarios() {
        print("\n=== Thermal safety monitor (I8 override, I9 sensor failure) ===")
        let clock = SimulatedClock()
        let (controller, smc) = makeController(.m4, clock: clock)
        let live = installSafetySensors(smc)
        checkSafetyMonitoring(controller, smc: smc, clock: clock, live: live)
        checkSensorFailure(controller, smc: smc, clock: clock, live: live)
    }

    /// M4 Max-like die keys: live probes, a gated P triplet, placeholders, and a peak-hold key.
    private func installSafetySensors(_ smc: FakeSMC) -> [FourCC] {
        let live: [FourCC] = ["Tp1i", "Tp1j", "Tp1k", "Tp1m", "Tpx9", "Te05", "Te06", "Tg05", "Tg0K"]
        for (n, key) in live.enumerated() { smc.setTemperature(key, 60 + Double(n)) }
        smc.setTemperature("Tp00", -4.0)
        smc.setTemperature("Tp01", 1.9)
        smc.setTemperature("Tp02", 0.0)
        smc.setTemperature("Tp0S", 40.0)
        smc.setTemperature("Tf06", 93.36)
        smc.setTemperature("Tp0X", 99.0)
        return live
    }

    private func checkSafetyMonitoring(_ controller: SMCFanController, smc: FakeSMC,
                                       clock: SimulatedClock, live: [FourCC]) {
        checkMonitoredSafetyKeys(controller)
        checkIdleSafety(controller)
        let ramp = SafetyRamp(smc: smc, clock: clock, live: live)
        checkStaticSafety(controller, ramp: ramp)
        checkHeatSafety(controller, ramp: ramp)
    }

    private func checkMonitoredSafetyKeys(_ controller: SMCFanController) {
        _ = try? controller.setManual(0, targetRPM: 2000)
        _ = try? controller.setManual(1, targetRPM: 2000)
        let keys = controller.monitoredSafetyKeys
        print("   monitored: \(keys.map(\.description).joined(separator: " "))")
        check(!keys.contains("Tf06"), "Tf06 (peak-hold, 93 °C) is not in the die set")
    }

    private func checkIdleSafety(_ controller: SMCFanController) {
        let verdict = controller.evaluateSafety()
        print("   idle: \(text(verdict))")
        if case .normal(let hottest) = verdict { check(hottest == 99, "gated (-4/1.9/0) and 40.0 values ignored; hottest = static Tp0X 99 for now") }
        else { check(false, "idle verdict") }
    }

    private func checkStaticSafety(_ controller: SMCFanController, ramp: SafetyRamp) {
        for _ in 0..<31 {
            ramp.step(60, spread: 1)
            _ = controller.evaluateSafety()
        }
        ramp.step(60, spread: 1)
        let verdict = controller.evaluateSafety()
        if case .normal(let hottest) = verdict { check((hottest ?? 99) < 70, "Tp0X unchanged for > 30 s is dropped (hottest now \(hottest.map { String(format: "%.1f", $0) } ?? "—"))") }
        else { check(false, "static key") }
    }

    private func checkHeatSafety(_ controller: SMCFanController, ramp: SafetyRamp) {
        checkInitialOverride(controller, ramp: ramp)
        checkHeldOverride(controller, ramp: ramp)
        checkReleasedOverride(controller, ramp: ramp)
    }

    private func checkInitialOverride(_ controller: SMCFanController, ramp: SafetyRamp) {
        ramp.step(104, spread: 0)
        let verdict = controller.evaluateSafety()
        print("   104 °C: \(text(verdict))")
        if case .override = verdict { check(true, "top-4 ≥ 103 °C -> override (every fan to Mx)") }
        else { check(false, "override at 104") }
    }

    private func checkHeldOverride(_ controller: SMCFanController, ramp: SafetyRamp) {
        ramp.step(96, spread: 0)
        let verdict = controller.evaluateSafety()
        if case .override = verdict { check(true, "96 °C: override held (release below 95)") }
        else { check(false, "hold at 96") }
    }

    private func checkReleasedOverride(_ controller: SMCFanController, ramp: SafetyRamp) {
        ramp.step(94, spread: 0)
        let verdict = controller.evaluateSafety()
        print("   94 °C: \(text(verdict))")
        if case .normal = verdict { check(true, "94 °C: released") }
        else { check(false, "release at 94") }
    }

    private func checkSensorFailure(_ controller: SMCFanController, smc: FakeSMC, clock: SimulatedClock, live: [FourCC]) {
        for key in live + ["Tp0X"] { smc.removeKey(key) }
        var verdicts: [SafetyVerdict] = []
        for _ in 0..<3 {
            clock.advance(1)
            verdicts.append(controller.evaluateSafety())
        }
        print("   no readable die sensor: \(verdicts.map(text).joined(separator: ", "))")
        check(verdicts.last == .sensorFailure && verdicts.first != .sensorFailure, "3 ticks without a reading -> sensorFailure (restore System)")
        _ = controller.restoreAll(reason: "sensorFailure")
    }

    // MARK: SMCClientInspector classification (rule: a non-fan helper is never named)

    private var inspectorCases: [(String, String?, String?)] {
        let ph = "/Library/PrivilegedHelperTools/"
        return [
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
    }

    func inspectorScenarios() {
        print("\n=== SMC client naming (IOUserClientCreator + proc_pidpath), offline ===")
        for (name, path, expected) in inspectorCases {
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

    private typealias StrategyColumn = (name: String, strategy: FanStrategy)

    private let t0 = Date(timeIntervalSince1970: 1000)

    private func engineTick(_ engine: FanControlEngine, _ offset: Double,
                            temperatures: [TemperatureSource: Double] = [:], safety: Double = 70,
                            raw: Double = 75, pressure: ThermalPressure = .nominal, plan: FanPlan) -> [Int: FanCommand] {
        engine.tick(now: t0 + offset, temperatures: temperatures, safetyTempC: safety,
                    rawHottestC: raw, pressure: pressure, plan: plan)
    }

    private func strategyPlan(_ strategy: FanStrategy) -> FanPlan {
        var plan = FanPlan()
        plan.shared = strategy
        return plan
    }

    private func guardedPlan(_ strategy: FanStrategy) -> FanPlan {
        var plan = strategyPlan(strategy)
        plan.thermalGuard.enabled = true
        return plan
    }

    private func commandRPM(_ command: FanCommand) -> Double? {
        if case .rpm(let rpm) = command { return rpm }
        return nil
    }

    private func strategyColumns(_ sensor: TemperatureSource) -> [StrategyColumn] {
        [("fixed 40%", .fixedPercent(40)),
         ("autoMax 80", .autoMax(sensor: sensor, thresholdC: 80, hysteresisC: 5, minHoldSeconds: 10)),
         ("autoBoost 60-90/10s", .autoBoost(sensor: sensor, lowC: 60, highC: 90, minPercent: 0, maxPercent: 100, gradualSeconds: 10, hysteresisC: 3)),
         ("curve", .curve(sensor: sensor, points: [CurvePoint(55, 0), CurvePoint(70, 30), CurvePoint(85, 70), CurvePoint(95, 100)],
                          hysteresisC: 3, below: .system, smoothing: Smoothing(riseTau: 2, fallTau: 12),
                          slew: Slew(up: 25, down: 2, hold: 10)))]
    }

    private func temperatureRamp() -> [Double] {
        var ramp: [Double] = []
        for i in 0...53 { ramp.append(45 + Double(i)) }
        for _ in 0..<10 { ramp.append(98) }
        for i in 0...53 { ramp.append(98 - Double(i)) }
        for _ in 0..<60 { ramp.append(45) }
        return ramp
    }

    private func engineRampScenario() {
        print("\n=== Engine strategies (synthetic ramp 45 -> 98 -> 45 °C at 1 °C/s, 1 s ticks) ===")
        let sensor = TemperatureSource.sensor(.smc("Tp01"))
        let strategies = strategyColumns(sensor)
        printStrategyHeader(strategies)
        let table = runStrategyRamp(strategies, sensor: sensor)
        checkStrategyResults(table)
    }

    private func printStrategyHeader(_ strategies: [StrategyColumn]) {
        var header = "  t   temp |"
        for (name, _) in strategies { header += " " + name.padding(toLength: 20, withPad: " ", startingAt: 0) + "|" }
        print(header)
    }

    private func runStrategyRamp(_ strategies: [StrategyColumn], sensor: TemperatureSource) -> [[FanCommand]] {
        let engines = strategies.map { _ in FanControlEngine(profile: Self.simProfile) }
        var table: [[FanCommand]] = []
        for (i, temperature) in temperatureRamp().enumerated() {
            let result = strategyRampRow(i, temperature: temperature, strategies: strategies, engines: engines, sensor: sensor)
            table.append(result.commands)
            if i % 6 == 0 { print(result.line) }
        }
        return table
    }

    private func strategyRampRow(_ i: Int, temperature: Double, strategies: [StrategyColumn],
                                 engines: [FanControlEngine], sensor: TemperatureSource)
        -> (commands: [FanCommand], line: String) {
        var line = String(format: "%4d %5.1f |", i, temperature)
        var commands: [FanCommand] = []
        for (j, column) in strategies.enumerated() {
            let out = engineTick(engines[j], Double(i), temperatures: [sensor: temperature], safety: temperature, raw: temperature, plan: strategyPlan(column.strategy))
            commands.append(out[0] ?? .system)
            line += " " + "\(out[0] ?? .system)".padding(toLength: 20, withPad: " ", startingAt: 0) + "|"
        }
        return (commands, line)
    }

    private func checkStrategyResults(_ table: [[FanCommand]]) {
        check(commandRPM(table[24][0]) == 3121, "fixed 40 % = 3121 rpm below the floor zone")
        check((commandRPM(table[54][0]) ?? 0) > 4500, "fixed: safety floor kicks in near 98 °C (\(table[54][0]))")
        check(table[30][1] == .system && commandRPM(table[36][1]) == 5777 && table[96][1] == .system, "autoMax: System -> 5777 at 80 °C -> System after cooling")
        check(commandRPM(table[78][3]) == 5777, "curve: hold at max while cooling (t=78)")
        check((commandRPM(table[96][3]) ?? 0) < 5777 && (commandRPM(table[96][3]) ?? 0) > (commandRPM(table[114][3]) ?? 0), "curve: slow descent after the hold")
        check(table.last?[3] == .system, "curve: released to System at 45 °C")
    }

    private func allOrNothingPlan() -> FanPlan {
        var plan = FanPlan()
        plan.linked = false
        plan.perFan = [0: .fixedPercent(60), 1: .system]
        return plan
    }

    private func allOrNothingScenario() {
        print("\n=== All-or-nothing on Ftst hardware ===")
        let plan = allOrNothingPlan()
        let engine = FanControlEngine(profile: Self.simProfile)
        let output = engine.tick(now: Date(), temperatures: [:], safetyTempC: 50, rawHottestC: 50, pressure: .nominal, plan: plan)
        print("   fan0 fixed 60 %, fan1 System -> \(output.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))")
        check(output[0] == .rpm(4006) && output[1] == .rpm(4006), "both fans 4006 rpm")
        checkPerFanM5(plan)
    }

    private func checkPerFanM5(_ plan: FanPlan) {
        var profile = FanHardwareProfile(fans: Self.simProfile.fans, scheme: .appleSilicon(modeKeyTemplate: FanHardwareProfile.modeLower, hasFtst: false))
        profile.hasFtstKey = false
        let engine = FanControlEngine(profile: profile)
        let output = engine.tick(now: Date(), temperatures: [:], safetyTempC: 50, rawHottestC: 50, pressure: .nominal, plan: plan)
        check(output[0] == .rpm(4006) && output[1] == .system, "M5 (no Ftst): per-fan control, fan 1 stays System")
    }

    private func safetyLatchScenario() {
        let plan = strategyPlan(.fixedPercent(20))
        let engine = FanControlEngine(profile: Self.simProfile)
        _ = engineTick(engine, 0, safety: 70, raw: 80, plan: plan)
        let spike = engineTick(engine, 1, safety: 72, raw: 106, plan: plan)
        check(spike[0] == .rpm(5777) && engine.safetyLatched, "raw hottest 106 °C ≥ 105 -> every forced fan 100 %")
        checkLatchHold(engine, plan: plan)
        checkLatchReleaseAndSystem(engine, plan: plan)
    }

    private func checkLatchHold(_ engine: FanControlEngine, plan: FanPlan) {
        var held = true
        for second in 2...9 {
            held = held && engineTick(engine, Double(second), safety: 70, raw: 80, plan: plan)[0] == .rpm(5777)
        }
        check(held, "latch holds ≥ 10 s after a single raw spike")
    }

    private func checkLatchReleaseAndSystem(_ engine: FanControlEngine, plan: FanPlan) {
        let after = engineTick(engine, 12, safety: 70, raw: 80, plan: plan)
        check(!engine.safetyLatched && after[0] == .rpm(2235), "released below critical − hysteresis (94 °C) after the hold -> back to 20 % (\(after[0] ?? .system))")
        let systemOutput = engineTick(engine, 13, safety: 110, raw: 110, plan: FanPlan())
        check(systemOutput[0] == .system, "System fans stay System even when latched (macOS handles them)")
    }

    private func sensorLossScenario() {
        let plan = strategyPlan(FanPresets.curve(.balanced).strategy)
        let engine = FanControlEngine(profile: Self.simProfile)
        if case .curve(let input, _, _, _, _, _) = plan.shared {
            _ = engineTick(engine, 0, temperatures: [input: 88], safety: 80, raw: 85, plan: plan)
            let lost = engineTick(engine, 1, safety: 80, raw: 85, plan: plan)
            if case .rpm(let rpm)? = lost[0] { check(rpm >= Self.simProfile.fans[0].rpm(forPercent: 50), "curve input lost -> hold current speed, ≥ 50 % (\(Int(rpm)) rpm)") }
            else { check(false, "curve input lost must hold") }
        }
    }

    private func thermalGuardScenario() {
        let plan = guardedPlan(.fixedPercent(20))
        let engine = FanControlEngine(profile: Self.simProfile)
        var output: [Int: FanCommand] = [:]
        for second in 0...5 { output = engineTick(engine, Double(second), pressure: .moderate, plan: plan) }
        check(engine.thermalGuardActive && output[0] == .rpm(Self.simProfile.fans[0].rpm(forPercent: 70).rounded()), "guard: moderate pressure for 5 s -> 70 % floor (\(output[0] ?? .system))")
        output = engineTick(engine, 6, pressure: .heavy, plan: plan)
        check(output[0] == .rpm(5777), "guard: heavy pressure -> 100 %")
        checkGuardRelease(engine, plan: plan)
    }

    private func checkGuardRelease(_ engine: FanControlEngine, plan: FanPlan) {
        var output: [Int: FanCommand] = [:]
        for second in 7...36 { output = engineTick(engine, Double(second), plan: plan) }
        let released = engineTick(engine, 37, plan: plan)
        output = released
        check(!engine.thermalGuardActive && output[0] == .rpm(2235), "guard: released after 30 s at nominal -> 20 % again")
    }

    private func systemGuardScenario() {
        var plan = guardedPlan(.system)
        let engine = FanControlEngine(profile: Self.simProfile)
        var output: [Int: FanCommand] = [:]
        for second in 0...6 { output = engineTick(engine, Double(second), pressure: .heavy, plan: plan) }
        check(output[0] == .system, "guard never takes control in System mode by default")
        plan.thermalGuard.applyInSystemMode = true
        output = engineTick(engine, 7, pressure: .heavy, plan: plan)
        check(output[0] == .system, "applyInSystemMode is ignored: Auto stays macOS's at heavy pressure")
        checkSystemSafety(engine, plan: plan)
    }

    private func checkSystemSafety(_ engine: FanControlEngine, plan: FanPlan) {
        let output = engineTick(engine, 8, safety: 110, raw: 112, pressure: .heavy, plan: plan)
        check(output[0] == .system, "the safety latch never takes a fan from Auto either")
    }

    private func curveSpikePlan() -> FanPlan {
        var config = FanUserConfig()
        config.mode = .curve
        return FanPlanBuilder.plan(config: config, power: .ac, profile: Self.simProfile)
    }

    /// Curve released below its first point, then a raw spike takes every fan straight to maximum.
    private func curveSafetyScenario() {
        let plan = curveSpikePlan()
        let inputs = Dictionary(uniqueKeysWithValues: plan.referencedSources.map { ($0, 50.0) })
        let engine = FanControlEngine(profile: Self.simProfile)
        let below = engineTick(engine, 0, temperatures: inputs, safety: 50, raw: 55, plan: plan)
        check(below[0] == .system && below[1] == .system, "curve below its first point leaves the fans to macOS")
        let hot = engineTick(engine, 1, temperatures: inputs, safety: 50, raw: 110, plan: plan)
        check(hot[0] == .rpm(5777) && hot[1] == .rpm(5777),
              "safety latch in Curve mode: both fans straight to maximum in one tick, even below the curve")
    }

    private func stopTick(_ engine: FanControlEngine, curve: FanCurve, plan: FanPlan,
                          _ offset: Double, _ temperature: Double, raw: Double = 60) -> [Int: FanCommand] {
        engineTick(engine, offset, temperatures: [curve.input: temperature], safety: 60, raw: raw, plan: plan)
    }

    /// Stop below the first point, restart, stop after the slow-down hold, then verify the safety lift.
    private func stopCurveScenario() {
        var curve = FanPresets.curve(.balanced)
        curve.below = .stop
        let plan = strategyPlan(curve.strategy)
        let engine = FanControlEngine(profile: Self.simProfile)
        let initial = stopTick(engine, curve: curve, plan: plan, 0, 60)
        check(initial[0] == .rpm(0) && initial[1] == .rpm(0), "stop below the first point: both fans 0 rpm at 60 °C")
        let stoppedAt = restartAndFindStopped(engine, curve: curve, plan: plan, initial: initial)
        checkStopSafety(engine, curve: curve, plan: plan, stoppedAt: stoppedAt)
    }

    private func restartAndFindStopped(_ engine: FanControlEngine, curve: FanCurve, plan: FanPlan,
                                       initial: [Int: FanCommand]) -> Int? {
        var output = initial
        for second in 1...10 { output = stopTick(engine, curve: curve, plan: plan, Double(second), 76) }
        if case .rpm(let rpm)? = output[0] { check(rpm >= 1350, "restarted at the first point: \(Int(rpm)) rpm at 76 °C") }
        else { check(false, "restarted at the first point") }
        return findStoppedAt(engine, curve: curve, plan: plan)
    }

    private func findStoppedAt(_ engine: FanControlEngine, curve: FanCurve, plan: FanPlan) -> Int? {
        var stoppedAt: Int?
        for second in 11...400 {
            let output = stopTick(engine, curve: curve, plan: plan, Double(second), 60)
            if output[0] == .rpm(0) { stoppedAt = second; break }
        }
        check(stoppedAt != nil, "stopped again \((stoppedAt ?? 0) - 10) s after cooling to 60 °C (hold + slow-down)")
        return stoppedAt
    }

    private func checkStopSafety(_ engine: FanControlEngine, curve: FanCurve, plan: FanPlan, stoppedAt: Int?) {
        let output = stopTick(engine, curve: curve, plan: plan, Double((stoppedAt ?? 400) + 1), 60, raw: 110)
        check(output[0] == .rpm(5777) && output[1] == .rpm(5777), "safety latch lifts stopped fans straight to maximum")
    }

    private func deadbandScenario() {
        var plan = strategyPlan(.fixedPercent(40))
        let engine = FanControlEngine(profile: Self.simProfile)
        _ = engineTick(engine, 0, safety: 60, raw: 60, plan: plan)
        plan.shared = .fixedPercent(40.5)                     // +22 rpm: inside the 50 rpm deadband
        let first = engineTick(engine, 1, safety: 60, raw: 60, plan: plan)
        var second: [Int: FanCommand] = [:]
        for offset in 2...6 { second = engineTick(engine, Double(offset), safety: 60, raw: 60, plan: plan) }
        check(first[0] == .rpm(3121) && second[0] == .rpm(3143), "deadband: a 22 rpm change is sent only after 5 s of stability (\(first[0] ?? .system) -> \(second[0] ?? .system))")
    }

    /// Hysteresis band of a releasing curve: engage at the first point, release below first − hysteresis.
    private func curveHysteresisScenario() {
        let curve = FanPresets.curve(.balanced)
        let plan = strategyPlan(curve.strategy)
        let engine = FanControlEngine(profile: Self.simProfile)
        let engagements = countEngagements(engine, curve: curve, plan: plan)
        check(engagements <= 1, "input hovering ±1 °C around the first point engages at most once in 2 min (\(engagements))")
        checkCurveRelease(engine, curve: curve, plan: plan)
    }

    private func countEngagements(_ engine: FanControlEngine, curve: FanCurve, plan: FanPlan) -> Int {
        var state = (engagements: 0, wasSystem: true)
        let first = curve.points[0].celsius
        for second in 0..<120 {
            let temperature = first + (second % 2 == 0 ? -1.5 : 0.6)
            let out = engineTick(engine, Double(second), temperatures: [curve.input: temperature], plan: plan)
            let isSystem = out[0] == .system
            if state.wasSystem && !isSystem { state.engagements += 1 }
            state.wasSystem = isSystem
        }
        return state.engagements
    }

    private func checkCurveRelease(_ engine: FanControlEngine, curve: FanCurve, plan: FanPlan) {
        let temperature = curve.points[0].celsius - curve.hysteresisC - 6
        let cool = engineTick(engine, 121, temperatures: [curve.input: temperature], safety: 60, raw: 60, plan: plan)
        var released = cool[0] == .system
        for second in 122..<160 where !released {
            released = engineTick(engine, Double(second), temperatures: [curve.input: temperature], safety: 60, raw: 60, plan: plan)[0] == .system
        }
        check(released, "released to System once the input is below first − hysteresis")
    }

    /// Fixed 30 %: latched at 101 °C, then held in the hysteresis band across resetState.
    private func resetLatchScenario() {
        let plan = strategyPlan(.fixedPercent(30))
        let engine = FanControlEngine(profile: Self.simProfile)
        _ = engineTick(engine, 0, safety: 101, raw: 101, plan: plan)
        for second in 1...4 { _ = engineTick(engine, Double(second), safety: 97, raw: 97, plan: plan) }
        engine.resetState()
        checkResetBand(engine, plan: plan)
        checkResetCooling(engine, plan: plan)
    }

    private func checkResetBand(_ engine: FanControlEngine, plan: FanPlan) {
        var output: [Int: FanCommand] = [:]
        for second in 5...20 { output = engineTick(engine, Double(second), safety: 97, raw: 97, plan: plan) }
        check(engine.safetyLatched && output[0] == .rpm(5777), "reset at 97 °C (latched at 101): still 100 % (\(output[0] ?? .system))")
    }

    private func checkResetCooling(_ engine: FanControlEngine, plan: FanPlan) {
        var output: [Int: FanCommand] = [:]
        for second in 21...60 { output = engineTick(engine, Double(second), safety: 85, raw: 85, plan: plan) }
        check(!engine.safetyLatched && output[0] == .rpm(2678), "released below 94 °C -> back to 30 % (\(output[0] ?? .system))")
    }

    private func earlyResetAndWakeScenario() {
        earlyResetScenario()
        wakeScenario()
    }

    private func earlyResetScenario() {
        let plan = strategyPlan(.fixedPercent(30))
        let engine = FanControlEngine(profile: Self.simProfile)
        _ = engineTick(engine, 0, raw: 106, plan: plan)
        engine.resetState()
        let early = engineTick(engine, 2, safety: 70, raw: 80, plan: plan)
        check(engine.safetyLatched && early[0] == .rpm(5777), "reset 2 s after a raw 106 °C spike: the 10 s minimum latch still holds")
    }

    private func wakeScenario() {
        let plan = strategyPlan(.fixedPercent(30))
        let engine = FanControlEngine(profile: Self.simProfile)
        _ = engineTick(engine, 0, safety: 101, raw: 101, plan: plan)
        let woke = engineTick(engine, 3600, safety: 60, raw: 62, plan: plan)
        check(!engine.safetyLatched && woke[0] == .rpm(2678), "after a 1 h gap (sleep) the latch re-evaluates from the fresh 60 °C")
    }

    private func performancePlan(_ source: TemperatureSource) -> FanPlan {
        var plan = FanPlan()
        plan.shared = .curve(sensor: source, points: [CurvePoint(50, 25), CurvePoint(82, 100)], hysteresisC: 2,
                             below: .minimum, smoothing: Smoothing(riseTau: 1, fallTau: 8), slew: Slew(up: 50, down: 3, hold: 20))
        return plan
    }

    /// A performance-like non-releasing curve driven by a power-gated P-cluster die.
    private func gatedInputScenario() {
        let source = TemperatureSource.sensor(.smc("Tp0D"))
        let plan = performancePlan(source)
        let engine = FanControlEngine(profile: Self.simProfile)
        var idle: [Int: FanCommand] = [:]
        for second in 0..<10 { idle = engineTick(engine, Double(second), temperatures: [source: 45], safety: 60, raw: 62, plan: plan) }
        checkGatedAndLost(engine, source: source, plan: plan, idle: idle)
    }

    private func checkGatedAndLost(_ engine: FanControlEngine, source: TemperatureSource,
                                   plan: FanPlan, idle: [Int: FanCommand]) {
        let gated = engine.tick(now: t0 + 10, temperatures: [:], gated: [source], safetyTempC: 60, rawHottestC: 62, pressure: .nominal, plan: plan)
        check(idle[0] == .rpm(2457) && gated[0] == idle[0], "gated input keeps its last value: \(idle[0] ?? .system) -> \(gated[0] ?? .system), not ≥ 50 %")
        check(engine.smoothedTemperature(source).map { abs($0 - 45) < 0.5 } == true, "gated: the operating point stays at the last reading")
        let lost = engineTick(engine, 11, safety: 60, raw: 62, plan: plan)
        check(lost[0] == .rpm(3564), "a truly missing input still gets the fail-safe ≥ 50 % (\(lost[0] ?? .system))")
    }

    private func staleEMAScenario() {
        let balanced = FanPresets.curve(.balanced)
        let cool = FanPresets.curve(.cool)
        let engine = FanControlEngine(profile: Self.simProfile)
        runBalancedThenCool(engine, balanced: balanced, cool: cool)
        let operatingPoint = engine.smoothedTemperature(cool.input)
        check(balanced.input == cool.input && operatingPoint.map { abs($0 - 80) < 0.5 } == true,
              "after a preset switch the operating point follows the new curve (\(operatingPoint.map { String(format: "%.1f", $0) } ?? "—") °C, input 80)")
    }

    /// One input with two EMA keys: the operating point must follow the active curve.
    private func runBalancedThenCool(_ engine: FanControlEngine, balanced: FanCurve, cool: FanCurve) {
        let balancedPlan = strategyPlan(balanced.strategy)
        let coolPlan = strategyPlan(cool.strategy)
        for second in 0..<5 { _ = engineTick(engine, Double(second), temperatures: [balanced.input: 70], safety: 70, raw: 72, plan: balancedPlan) }
        for second in 5..<40 { _ = engineTick(engine, Double(second), temperatures: [cool.input: 80], safety: 70, raw: 72, plan: coolPlan) }
    }

    private func engineProtectionScenarios() {
        print("\n=== Safety latch, sensor loss, thermal guard, deadband ===")
        safetyLatchScenario()
        sensorLossScenario()
        thermalGuardScenario()
        systemGuardScenario()
        curveSafetyScenario()
        guardLatchReleasedDemandScenario()
        stopCurveScenario()
        deadbandScenario()
        curveHysteresisScenario()
    }

    private func engineStateScenarios() {
        print("\n=== resetState keeps the safety latch; gated inputs; stale EMAs ===")
        resetLatchScenario()
        earlyResetAndWakeScenario()
        gatedInputScenario()
        staleEMAScenario()
    }

    func engineScenarios() {
        engineRampScenario()

        allOrNothingScenario()

        engineProtectionScenarios()

        engineStateScenarios()
    }

    private func releasedGuardPlan(_ curve: FanCurve) -> FanPlan {
        var plan = FanPlan()
        plan.shared = curve.strategy
        plan.thermalGuard.enabled = true
        return plan
    }

    private func primeEngagedGuard(_ engine: FanControlEngine, inputs: [TemperatureSource: Double], plan: FanPlan) {
        for s in 0...5 {
            _ = engine.tick(now: Date(timeIntervalSince1970: 1000 + Double(s)), temperatures: inputs,
                            safetyTempC: 70, rawHottestC: 75, pressure: .heavy, plan: plan)
        }
    }

    private func guardLatchReleasedDemandScenario() {
        let curve = FanPresets.curve(.balanced)
        let plan = releasedGuardPlan(curve)
        let engine = FanControlEngine(profile: Self.simProfile)
        let inputs: [TemperatureSource: Double] = [curve.input: 50]
        primeEngagedGuard(engine, inputs: inputs, plan: plan)
        let hot = engine.tick(now: Date(timeIntervalSince1970: 1006), temperatures: inputs,
                              safetyTempC: 70, rawHottestC: 110, pressure: .heavy, plan: plan)
        check(hot[0] == .rpm(5777) && hot[1] == .rpm(5777) && engine.safetyLatched && !engine.thermalGuardActive,
              "engaged guard + safety latch + released curve: max output does not mark the guard applied")
    }

    // MARK: Plan builder and presets

    func planAndPresetScenarios() {
        planBuilderScenarios()
        presetDayScenarios()
    }

    private func planBuilderScenarios() {
        print("\n=== FanPlanBuilder (SPEC §2.9.2 table) ===")
        checkBasicPlans()
        let curveConfig = checkCurvePlans()
        checkGuardCopied(curveConfig)
    }

    private func checkBasicPlans() {
        var config = FanUserConfig()
        config.mode = .system
        check(FanPlanBuilder.plan(config: config, power: .ac, profile: Self.simProfile).shared == .system, "System -> shared .system")
        config.mode = .max
        check(FanPlanBuilder.plan(config: config, power: .ac, profile: Self.simProfile).shared == .fixedPercent(100), "Max -> fixedPercent(100)")
        checkFixedPlans(config)
    }

    private func checkFixedPlans(_ config: FanUserConfig) {
        var config = config
        config.mode = .fixed
        config.fixedPercent = 35
        check(FanPlanBuilder.plan(config: config, power: .ac, profile: Self.simProfile).shared == .fixedPercent(35), "Fixed linked -> shared fixedPercent(35)")
        config.linked = false
        config.fixedPercentPerFan = [1: 70]
        let unlinked = FanPlanBuilder.plan(config: config, power: .ac, profile: Self.simProfile)
        check(!unlinked.linked && unlinked.perFan[0] == .fixedPercent(35) && unlinked.perFan[1] == .fixedPercent(70), "Fixed unlinked -> perFan [0: 35, 1: 70]")
    }

    private func checkCurvePlans() -> FanUserConfig {
        var config = FanUserConfig()
        config.mode = .curve
        config.curveAC = FanPresets.curve(.quiet)
        config.curveBattery = FanPresets.curve(.cool)
        check(FanPlanBuilder.plan(config: config, power: .ac, profile: Self.simProfile).shared == FanPresets.curve(.quiet).strategy, "Curve on AC -> curveAC")
        check(FanPlanBuilder.plan(config: config, power: .battery, profile: Self.simProfile).shared == FanPresets.curve(.cool).strategy, "Curve on battery -> curveBattery")
        config.curveBattery = nil
        check(FanPlanBuilder.plan(config: config, power: .battery, profile: Self.simProfile).shared == FanPresets.curve(.quiet).strategy, "Curve on battery without curveBattery -> curveAC")
        return config
    }

    private func checkGuardCopied(_ config: FanUserConfig) {
        var config = config
        config.thermalGuard.enabled = true
        check(FanPlanBuilder.plan(config: config, power: .ac, profile: .none).shared == .system &&
              FanPlanBuilder.plan(config: config, power: .ac, profile: Self.simProfile).thermalGuard.enabled, "not controllable -> System; guard/safety copied")
    }

    private func presetDayScenarios() {
        print("\n=== Presets (M4 Max tuning) on a synthetic day: idle 64 °C -> load 80 °C -> hot 92 °C -> idle ===")
        let day = syntheticDay()
        for id in FanPresetID.allCases {
            presetDayScenario(id, day: day)
        }
    }

    private func syntheticDay() -> [Double] {
        var day: [Double] = Array(repeating: 64, count: 30)
        for i in 0..<16 { day.append(64 + Double(i)) }
        day += Array(repeating: 80, count: 30)
        for i in 0..<12 { day.append(80 + Double(i)) }
        day += Array(repeating: 92, count: 20)
        day += Array(repeating: 64, count: 150)
        return day
    }

    private func presetDayScenario(_ id: FanPresetID, day: [Double]) {
        let curve = FanPresets.curve(id)
        let samples = presetSamples(curve, day: day)
        printPresetSummary(id, curve: curve)
        printPresetTimeline(samples, dayCount: day.count)
        checkPresetIdle(id, samples: samples)
    }

    private func presetSamples(_ curve: FanCurve, day: [Double]) -> [(Int, FanCommand)] {
        let engine = FanControlEngine(profile: Self.simProfile)
        let plan = strategyPlan(curve.strategy)
        var samples: [(Int, FanCommand)] = []
        for (time, temperature) in day.enumerated() {
            let inputs = presetTemperatures(plan: plan, temperature: temperature)
            let out = engine.tick(now: Date(timeIntervalSince1970: Double(time)), temperatures: inputs, safetyTempC: temperature + 12,
                                  rawHottestC: temperature + 18, pressure: .nominal, plan: plan)
            samples.append((time, out[0] ?? .system))
        }
        return samples
    }

    private func presetTemperatures(plan: FanPlan, temperature: Double) -> [TemperatureSource: Double] {
        var temperatures: [TemperatureSource: Double] = [:]
        for source in plan.referencedSources {
            temperatures[source] = temperature + (source == .aggregate(.safetyTop4) ? 12 : 0)
        }
        return temperatures
    }

    private func printPresetSummary(_ id: FanPresetID, curve: FanCurve) {
        let points = curve.points.map { "\(Int($0.celsius))→\(Int($0.percent))" }.joined(separator: " ")
        print(String(format: "  %@ input %@ %@  hyst %.0f  ramp %.0f/%.0f s  hold %.0f s", pad(id.rawValue, 12) as NSString,
                     pad(describe(curve.input), 12) as NSString, points as NSString, curve.hysteresisC,
                     100 / curve.slew.upPercentPerSecond, 100 / curve.slew.downPercentPerSecond, curve.slew.downHoldSeconds))
    }

    private func printPresetTimeline(_ samples: [(Int, FanCommand)], dayCount: Int) {
        print("               idle \(presetCommand(samples, at: 29)) | load \(presetCommand(samples, at: 75)) | hot \(presetCommand(samples, at: 107)) | idle+60 s \(presetCommand(samples, at: 167)) | idle+150 s \(presetCommand(samples, at: dayCount - 1))")
    }

    private func presetCommand(_ samples: [(Int, FanCommand)], at index: Int) -> String {
        "\(samples[index].1)"
    }

    private func checkPresetIdle(_ id: FanPresetID, samples: [(Int, FanCommand)]) {
        switch id {
        case .quiet, .balanced: check(samples[29].1 == .system, "\(id.rawValue): System (fans may stop) at a 64 °C idle")
        case .cool, .performance: check(samples[29].1 != .system, "\(id.rawValue): keeps the fans spinning at idle")
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
