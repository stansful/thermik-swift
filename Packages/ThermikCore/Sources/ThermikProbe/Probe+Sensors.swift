// Probe+Sensors.swift — `thermik-probe sensors …` (READ-ONLY: SMC reads + HID events, no writes).
//
//   sensors groups              visible sensors by group, display-group stats, every HEADLINE aggregate, power, fans
//   sensors snapshot            every inventory sensor: raw value, valid/INVALID/gated, group, role, visibility;
//                               then every HID service instance
//   sensors bench               start(), visible pass, headline + safety pass, full pass, HID pass, aggregation
//   sensors watch [s] [--keys] [--wake]
//                               1 Hz for s seconds (default 20): aggregates + gated clusters per tick; with --keys
//                               (or s ≥ 60) a per-key min / max / Δ table for contributors (P1); --wake calls
//                               didWake() first, so the first 3 s show the post-wake window (P values forced invalid)
//   sensors discover [s]        schema-1 heuristic draft DB on stdout (ignores the bundled DB); with s > 0 it samples
//                               1 Hz for s seconds and runs the static / mirror / offset-copy detectors (P1)
//   sensors resolve <db> KEY[,KEY…] [--hid P1,P2…]
//                               dry run, no hardware: resolve bundled `<db>.json` (e.g. intel) — or, with
//                               `heuristic:<platform>`, the heuristics alone — against a key list as if this Mac exposed
//                               exactly those keys; prints inventory, headline sets and safety set
import Foundation
import ThermikCore
import ThermikSMC

extension Probe {
    static func sensors(_ args: [String]) async {
        let rest = Array(args.dropFirst())
        await SensorProbe.run(args.first ?? "groups", rest: rest)
    }
}

private enum SensorProbe {

    // MARK: Shared

    static func run(_ sub: String, rest: [String]) async {
        switch sub {
        case "groups": await groups()
        case "snapshot": await snapshot()
        case "bench": await bench()
        case "watch": await watch(rest)
        case "discover": await discover(seconds: max(0, numericSeconds(rest) ?? 0))
        case "resolve": resolve(rest)
        default: print("usage: thermik-probe sensors groups | snapshot | bench | watch [seconds] [--keys] [--wake] | discover [seconds] | resolve <db> KEY,… [--hid P,…]")
        }
    }

    static func numericSeconds(_ args: [String]) -> Int? { args.compactMap { Int($0) }.first }

    static func watch(_ args: [String]) async {
        let seconds = max(1, numericSeconds(args) ?? 20)
        await watch(seconds: seconds, perKey: args.contains("--keys"), simulateWake: args.contains("--wake"))
    }

    struct Session {
        let sampler: SensorSampler
        let inventory: SensorInventory
        let aggregator: SensorAggregator
        let byID: [SensorID: Sensor]
        var visible: Set<SensorID> { Set(inventory.sensors.filter(\.isVisibleByDefault).map(\.id)) }
        /// What the app reads while the popover is open: visible ∪ headline ∪ safety, in inventory order.
        var popoverRequest: [SensorID] {
            let want = visible.union(inventory.headline.values.flatMap { $0 }).union(inventory.safetySet)
            return inventory.sensors.map(\.id).filter { want.contains($0) }
        }
        var headlineAndSafety: [SensorID] {
            let want = Set(inventory.headline.values.flatMap { $0 }).union(inventory.safetySet)
            return inventory.sensors.map(\.id).filter { want.contains($0) }
        }
    }

    static func open() async -> Session? {
        let sampler = SensorSampler()
        do {
            let inv = try await sampler.start()
            return Session(sampler: sampler, inventory: inv, aggregator: SensorAggregator(inventory: inv),
                           byID: Dictionary(inv.sensors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        } catch {
            print("sensors unavailable: \(error)")
            return nil
        }
    }

    static func header(_ s: Session) async {
        let inv = s.inventory, id = inv.identity
        let visible = inv.sensors.filter(\.isVisibleByDefault).count
        let heuristic = inv.sensors.filter(\.isHeuristic).count
        let hid = inv.sensors.filter { $0.id.source == .hid }.count
        print("# platform=\(id.platformName) target=\(id.targetType ?? "-") model=\(id.modelIdentifier) chip=\(id.chipName) "
              + "smc=\(id.smcPlatform ?? "-") keys=\(inv.smcKeyCount) appleSilicon=\(id.isAppleSilicon)")
        print("# catalog=\(status(inv.catalogStatus)) sensors=\(inv.sensors.count) visible=\(visible) "
              + "hidden=\(inv.sensors.count - visible) heuristic=\(heuristic) hid=\(hid) smcAvailable=\(inv.smcAvailable) "
              + "start=\(ms(await s.sampler.startDuration))")
        printSetHeader(s)
    }

    static func printSetHeader(_ s: Session) {
        let inv = s.inventory
        let sets = HeadlineSet.allCases.compactMap { set in inv.headline[set].map { "\(set.rawValue)=\($0.count)" } }
        print("# headline: \(sets.joined(separator: " ")) safetySet=\(inv.safetySet.count)")
        print("# fans=\(inv.fanProfile.fans.count) scheme=\(inv.fanProfile.scheme) names=\(inv.fanNames?.joined(separator: "/") ?? "-")")
    }

    static func status(_ s: CatalogStatus) -> String {
        switch s {
        case .verified(let p): return "verified(\(p))"
        case .unverified(let p): return "unverified(\(p))"
        case .heuristic(let p): return "heuristic(\(p))"
        }
    }

    static func f1(_ v: Double?) -> String { v.map { String(format: "%5.1f", $0) } ?? "    —" }
    static func f2(_ v: Double?) -> String { v.map { String(format: "%8.2f", $0) } ?? "       -" }

    static func ms(_ d: Duration?) -> String {
        guard let d else { return "-" }
        return String(format: "%.1f ms", millis(d))
    }
    static func millis(_ d: Duration) -> Double { Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15 }

    static func powerLine(_ p: PowerValues) -> String {
        func w(_ v: Double?) -> String { v.map { String(format: "%.1f W", $0) } ?? "-" }
        return "POWER system \(w(p.systemTotalW))  dc-in \(w(p.dcInW))  battery \(w(p.batteryW))  soc≈ \(w(p.socW))"
    }

    static func fanLine(_ f: FanControlState?) -> String {
        guard let f else { return "FANS -" }
        let fans = f.fans.map { String(format: "F%d %.0f/%.0f rpm %@", $0.index, $0.actualRPM, $0.targetRPM, $0.mode?.description ?? "-") }
        return "FANS \(fans.joined(separator: "  "))  Ftst=\(f.ftst.map(String.init) ?? "-")"
    }

    static func clusterLabel(_ s: Sensor) -> String {
        guard let c = s.descriptor.cluster else { return s.group.rawValue }
        return "\(s.group.rawValue)#\(c + 1)"
    }

    /// "cpuPerformance#2(12) cpuAggregate#2(1)"
    static func gatedSummary(_ gated: Set<SensorID>, _ s: Session) -> String {
        var counts: [String: Int] = [:]
        for id in gated { if let sensor = s.byID[id] { counts[clusterLabel(sensor), default: 0] += 1 } }
        return counts.isEmpty ? "-" : counts.sorted { $0.key < $1.key }.map { "\($0.key)(\($0.value))" }.joined(separator: " ")
    }

    // MARK: groups

    static func groups() async {
        guard let s = await open() else { return }
        await header(s)
        let sampled = await samplePopover(s)
        printSensorGroups(sampled.frame, visible: sampled.visible, s: s)
        printDisplayGroups(sampled.frame, visible: sampled.visible, s: s)
        printAggregates(sampled.frame, visible: sampled.visible, s: s)
        print(powerLine(sampled.frame.power))
        print(fanLine(sampled.frame.fans))
        print("# gated: \(gatedSummary(sampled.frame.gated, s))  postWake=\(sampled.frame.isPostWake)")
        print("# timings: start \(ms(await s.sampler.startDuration)), read pass (\(s.popoverRequest.count) keys + fans + power) \(ms(sampled.passTime))")
    }

    static func samplePopover(_ s: Session) async -> (frame: SensorFrame, passTime: Duration, visible: Set<SensorID>) {
        let clock = ContinuousClock()
        let t0 = clock.now
        let frame = await s.sampler.sample(SampleRequest(sensorIDs: s.popoverRequest))
        let passTime = clock.now - t0
        let visible = s.visible
        return (frame, passTime, visible)
    }

    static func printSensorGroups(_ frame: SensorFrame, visible: Set<SensorID>, s: Session) {
        for g in SensorGroup.allCases {
            printSensorGroup(g, frame: frame, visible: visible, s: s)
        }
    }

    static func printSensorGroup(_ g: SensorGroup, frame: SensorFrame, visible: Set<SensorID>, s: Session) {
        let items = s.inventory.sensors.filter { $0.group == g && visible.contains($0.id) }
        guard !items.isEmpty else { return }
        let vals = items.compactMap { frame.values[$0.id] }
        let mean = vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
        print(String(format: "== %-15@ valid %2d/%2d  avg %@  max %@", g.rawValue as NSString, vals.count, items.count,
                     f1(mean), f1(vals.max())))
        for x in items { printSensor(x, frame: frame) }
    }

    static func printSensor(_ x: Sensor, frame: SensorFrame) {
        let v = frame.values[x.id]
        let state = v != nil ? "" : (frame.gated.contains(x.id) ? "  (gated)" : "  (invalid, raw \(f1(frame.raw[x.id]).trimmingCharacters(in: .whitespaces)))")
        print("     \(x.id.key)  \(v.map { String(format: "%5.1f °C", $0) } ?? "   —   ")  \(x.role.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))  "
              + "\(x.name(preferRussian: false))  /  \(x.name(preferRussian: true))\(state)")
    }

    static func printDisplayGroups(_ frame: SensorFrame, visible: Set<SensorID>, s: Session) {
        let stats = s.aggregator.groupStats(frame.values, visible: visible)
        for g in DisplayGroup.allCases {
            guard let st = stats[g] else { continue }
            print(String(format: "GROUP %-9@ mean %@  max %@  hottest %@  (%d/%d valid)", g.rawValue as NSString, f1(st.mean),
                         f1(st.max), (st.hottest?.key ?? "-") as NSString, st.valid, st.total))
        }
    }

    static func printAggregates(_ frame: SensorFrame, visible: Set<SensorID>, s: Session) {
        let agg = s.aggregator.aggregates(frame.values, visible: visible)
        let inputs = aggregateInputs(s, visible: visible)
        for k in AggregateKind.allCases {
            var line = String(format: "HEADLINE %-13@ %@ °C", k.rawValue as NSString, f1(agg[k]))
            if let ids = inputs[k] { line += "  (\(ids.filter { frame.values[$0] != nil }.count)/\(ids.count) valid)" }
            if let src = agg.sources[k] { line += "  source=\(src.key)" }
            print(line)
        }
    }

    static func aggregateInputs(_ s: Session, visible: Set<SensorID>) -> [AggregateKind: [SensorID]] {
        [
            .cpuAverage: s.inventory.headline[.cpu] ?? [], .cpuHottest: s.inventory.headline[.cpuHotspot] ?? [],
            .gpuAverage: s.inventory.headline[.gpu] ?? [], .gpuHottest: s.inventory.headline[.gpu] ?? [],
            .socDie: s.inventory.headline[.soc] ?? [], .memory: s.inventory.headline[.memory] ?? [],
            .ssd: s.inventory.headline[.ssd] ?? [], .battery: s.inventory.headline[.battery] ?? [],
            .safetyTop4: s.inventory.safetySet, .rawHottestDie: s.inventory.safetySet,
            .highestAll: Array(visible), .averageAll: Array(visible),
        ]
    }

    // MARK: snapshot

    static func snapshot() async {
        guard let s = await open() else { return }
        await header(s)
        let frame = await s.sampler.sample(SampleRequest(sensorIDs: s.inventory.sensors.map(\.id)))
        printSensorRows(frame, s: s)
        printSnapshotSummary(frame, s: s)
        await printHIDInstances(s)
        print(powerLine(frame.power))
        print(fanLine(frame.fans))
    }

    static func printSensorRows(_ frame: SensorFrame, s: Session) {
        print("# id\traw\tstate\tgroup\trole\tvisibility\ttype\tname\tnameRu")
        for x in s.inventory.sensors {
            let state = frame.values[x.id] != nil ? "ok" : (frame.gated.contains(x.id) ? "gated" : (frame.raw[x.id] == nil ? "unread" : "INVALID"))
            print("\(x.id)\t\(f2(frame.raw[x.id]))\t\(state)\t\(clusterLabel(x))\t\(x.role.rawValue)\t"
                  + "\(x.isVisibleByDefault ? "visible" : "hidden")\t\(x.smcType ?? "hid")\t\(x.name(preferRussian: false))\t\(x.name(preferRussian: true))")
        }
    }

    static func printSnapshotSummary(_ frame: SensorFrame, s: Session) {
        let keys = Set(s.inventory.sensors.map(\.id.key))
        let neverShown = s.inventory.sensors.filter { $0.role.isNeverShown }.count
        let peak = ["Tf06", "Tf16", "Tf26", "Tf36", "Tf46"].filter { keys.contains($0) }
        print("# never-shown roles in inventory: \(neverShown); Tf?6 peak-hold keys present: \(peak.isEmpty ? "none" : peak.joined(separator: " "))")
        print("# valid \(frame.values.count) / read \(frame.raw.count) / inventory \(s.inventory.sensors.count); gated \(gatedSummary(frame.gated, s))")
        print("# HID service instances")
    }

    static func printHIDInstances(_ s: Session) async {
        for h in await s.sampler.hidInstances() {
            print(String(format: "hid:%@\t%8.3f\tloc=%@\tregistry=0x%llx", h.product, h.value, h.location, h.registryID))
        }
    }

    // MARK: bench

    struct Stats {
        var samples: [Double] = []
        mutating func add(_ d: Duration) { samples.append(millis(d)) }
        var line: String {
            let s = samples.sorted()
            guard !s.isEmpty else { return "-" }
            let p90 = s[min(s.count - 1, Int(Double(s.count) * 0.9))]
            return String(format: "median %6.2f ms  p90 %6.2f  min %6.2f  max %6.2f  (n=%d)", s[s.count / 2], p90, s[0], s[s.count - 1], s.count)
        }
        var median: Double { samples.sorted()[samples.count / 2] }
    }

    struct BenchIDs {
        let visible: [SensorID]
        let headline: [SensorID]
        let all: [SensorID]
        let hid: [SensorID]
    }

    struct BenchPasses {
        let visible: Stats
        let visibleFull: Stats
        let headline: Stats
        let headlineFull: Stats
        let full: Stats
        let fansOnly: Stats
    }

    static func bench() async {
        print("# READ-ONLY timing benchmark. Other builds may be running in parallel: numbers can be noisy.")
        guard let started = await measureStarts() else { return }
        await header(started.session)
        let ids = benchIDs(started.session)
        let passes = await measurePasses(started.session, ids: ids)
        let hid = await measureHID(ids.hid)
        let aggregation = await measureAggregation(started.session)
        printBenchResults(start: started.stats, passes: passes, hid: hid, aggregation: aggregation, ids: ids)
        printBudgets(start: started.stats, passes: passes)
    }

    static func measureStarts() async -> (stats: Stats, session: Session)? {
        let clock = ContinuousClock()
        var start = Stats()
        var last: Session?
        for _ in 0..<5 {
            guard let opened = await timedOpen(clock: clock) else { return nil }
            start.add(opened.duration)
            last = opened.session
        }
        guard let last else { return nil }
        return (start, last)
    }

    static func timedOpen(clock: ContinuousClock) async -> (session: Session, duration: Duration)? {
        let t0 = clock.now
        guard let s = await open() else { return nil }
        return (s, clock.now - t0)
    }

    static func benchIDs(_ s: Session) -> BenchIDs {
        let visible = s.inventory.sensors.filter { $0.isVisibleByDefault && $0.id.source == .smc }.map(\.id)
        let headline = s.headlineAndSafety.filter { $0.source == .smc }
        let all = s.inventory.sensors.filter { $0.id.source == .smc }.map(\.id)
        let hid = s.inventory.sensors.filter { $0.id.source == .hid }.map(\.id)
        return BenchIDs(visible: visible, headline: headline, all: all, hid: hid)
    }

    static func measurePasses(_ s: Session, ids: BenchIDs) async -> BenchPasses {
        let clock = ContinuousClock()
        let visible = await measurePass(s, clock: clock, ids: ids.visible, components: [], n: 30)
        let visibleFull = await measurePass(s, clock: clock, ids: ids.visible, components: [.fans, .power], n: 30)
        let headline = await measurePass(s, clock: clock, ids: ids.headline, components: [], n: 30)
        let headlineFull = await measurePass(s, clock: clock, ids: ids.headline, components: [.fans, .power], n: 30)
        let full = await measurePass(s, clock: clock, ids: ids.all, components: [], n: 10)
        let fansOnly = await measurePass(s, clock: clock, ids: [], components: .fans, n: 30)
        return BenchPasses(visible: visible, visibleFull: visibleFull, headline: headline,
                           headlineFull: headlineFull, full: full, fansOnly: fansOnly)
    }

    static func measurePass(_ s: Session, clock: ContinuousClock, ids: [SensorID],
                            components: SampleRequest.Components, n: Int) async -> Stats {
        var st = Stats()
        for _ in 0..<n {
            let t0 = clock.now
            _ = await s.sampler.sample(SampleRequest(sensorIDs: ids, components: components))
            st.add(clock.now - t0)
        }
        return st
    }

    /// HID: a fresh sampler per pass, so each pass really reads (the sampler caches HID values for 5 s).
    static func measureHID(_ ids: [SensorID]) async -> Stats {
        guard !ids.isEmpty else { return Stats() }
        let clock = ContinuousClock()
        var hid = Stats()
        for _ in 0..<3 {
            guard let fresh = await open() else { break }
            let t0 = clock.now
            _ = await fresh.sampler.sample(SampleRequest(sensorIDs: ids, components: []))
            hid.add(clock.now - t0)
        }
        return hid
    }

    /// Aggregation on the main-actor side (SensorStore.consume): aggregates + groupStats on a full frame.
    static func measureAggregation(_ s: Session) async -> (stats: Stats, frame: SensorFrame) {
        let frame = await s.sampler.sample(SampleRequest(sensorIDs: s.inventory.sensors.map(\.id)))
        let visible = s.visible
        let clock = ContinuousClock()
        var agg = Stats()
        for _ in 0..<200 {
            agg.add(aggregationPass(s, frame: frame, visible: visible, clock: clock))
        }
        return (agg, frame)
    }

    static func aggregationPass(_ s: Session, frame: SensorFrame, visible: Set<SensorID>, clock: ContinuousClock) -> Duration {
        let t0 = clock.now
        _ = s.aggregator.aggregates(frame.values, visible: visible)
        _ = s.aggregator.groupStats(frame.values, visible: visible)
        return clock.now - t0
    }

    static func printBenchResults(start: Stats, passes: BenchPasses, hid: Stats,
                                  aggregation: (stats: Stats, frame: SensorFrame), ids: BenchIDs) {
        print("start() fresh sampler (SMC open + #KEY + catalog + HID + fans) \(start.line)")
        print("visible pass        (\(ids.visible.count) SMC keys)                \(passes.visible.line)")
        print("visible pass + fans + power                    \(passes.visibleFull.line)")
        print("headline+safety pass (\(ids.headline.count) SMC keys)              \(passes.headline.line)")
        print("headline+safety + fans + power                 \(passes.headlineFull.line)")
        print("full inventory pass (\(ids.all.count) SMC keys)              \(passes.full.line)")
        print("fans snapshot only                             \(passes.fansOnly.line)")
        print("HID pass            (\(ids.hid.count) products, uncached)         \(hid.line)")
        print("aggregates+groupStats (\(aggregation.frame.values.count) values)             \(aggregation.stats.line)")
    }

    static func printBudgets(start: Stats, passes: BenchPasses) {
        verdict("start()", start.median, 150)
        verdict("visible pass", passes.visible.median, 20)
        verdict("headline+safety pass", passes.headline.median, 10)
    }

    static func verdict(_ name: String, _ v: Double, _ budget: Double) {
        print(String(format: "BUDGET %-22@ %7.2f ms ≤ %5.1f ms  %@", name as NSString, v, budget, v <= budget ? "PASS" : "MISS"))
    }

    // MARK: watch

    static let shownAggregates: [(AggregateKind, String)] = [
        (.cpuAverage, "cpu"), (.cpuHottest, "cpuHot"), (.gpuAverage, "gpu"), (.gpuHottest, "gpuHot"),
        (.socDie, "die"), (.memory, "mem"), (.ssd, "ssd"), (.battery, "bat"),
        (.safetyTop4, "top4"), (.rawHottestDie, "rawHot"), (.highestAll, "high"),
    ]

    struct WatchState {
        var postWakeTicks = 0, postWakeValidP = 0
        var violations: [String] = []
        var gatedTicks = 0
        var gatedSeen = Set<String>()
        var aggSeries: [AggregateKind: [Double]] = [:]
        var keySeries: [SensorID: (min: Double, max: Double, first: Double, last: Double, valid: Int)] = [:]

        mutating func record(_ frame: SensorFrame, _ agg: AggregateValues, gated: String, tick: Int, s: Session) {
            recordAggregates(agg, tick: tick)
            recordKeys(frame)
            recordPostWake(frame, s: s)
            recordGated(frame.gated, summary: gated)
        }

        mutating func recordAggregates(_ agg: AggregateValues, tick: Int) {
            for k in AggregateKind.allCases {
                guard let v = agg[k] else { continue }
                aggSeries[k, default: []].append(v)
                if v == 0 || v == 40.0 { violations.append("t=\(tick) \(k.rawValue)=\(v)") }
            }
        }

        mutating func recordKeys(_ frame: SensorFrame) {
            for (id, v) in frame.values {
                if var e = keySeries[id] {
                    e.min = min(e.min, v)
                    e.max = max(e.max, v)
                    e.last = v
                    e.valid += 1
                    keySeries[id] = e
                } else { keySeries[id] = (v, v, v, v, 1) }
            }
        }

        mutating func recordPostWake(_ frame: SensorFrame, s: Session) {
            guard frame.isPostWake else { return }
            postWakeTicks += 1
            postWakeValidP += frame.values.keys.filter { [.cpuPerformance, .cpuFabric, .cpuAggregate].contains(s.byID[$0]?.group) }.count
        }

        mutating func recordGated(_ gated: Set<SensorID>, summary: String) {
            guard !gated.isEmpty else { return }
            gatedTicks += 1
            gatedSeen.formUnion(summary.split(separator: " ").map { String($0.prefix { $0 != "(" }) })
        }
    }

    static func watch(seconds: Int, perKey: Bool, simulateWake: Bool) async {
        guard let s = await open() else { return }
        await header(s)
        if simulateWake { await s.sampler.didWake() }
        let request = SampleRequest(sensorIDs: s.popoverRequest)
        let state = await runWatch(s, request: request, seconds: seconds)
        printWatchSummary(state, seconds: seconds)
        if simulateWake { printPostWakeSummary(state) }
        if perKey || seconds >= 60 { printPerKeyDeltas(state, s: s, request: request, seconds: seconds) }
    }

    static func runWatch(_ s: Session, request: SampleRequest, seconds: Int) async -> WatchState {
        var state = WatchState()
        let visible = s.visible
        let clock = ContinuousClock()
        var next = clock.now
        print("# \(seconds) s at 1 Hz, request = visible ∪ headline ∪ safety (\(request.sensorIDs.count) ids) + fans + power")
        await runWatchTicks(s, request: request, seconds: seconds, visible: visible, clock: clock, next: &next, state: &state)
        return state
    }

    static func runWatchTicks(_ s: Session, request: SampleRequest, seconds: Int, visible: Set<SensorID>,
                              clock: ContinuousClock, next: inout ContinuousClock.Instant, state: inout WatchState) async {
        for tick in 0..<seconds {
            let t0 = clock.now
            let frame = await s.sampler.sample(request)
            let cost = clock.now - t0
            recordAndPrintTick(frame, tick: tick, cost: cost, s: s, request: request, visible: visible, state: &state)
            await waitForNextTick(clock, next: &next, tick: tick, seconds: seconds)
        }
    }

    static func recordAndPrintTick(_ frame: SensorFrame, tick: Int, cost: Duration, s: Session,
                                   request: SampleRequest, visible: Set<SensorID>, state: inout WatchState) {
        let agg = s.aggregator.aggregates(frame.values, visible: visible)
        let gated = gatedSummary(frame.gated, s)
        state.record(frame, agg, gated: gated, tick: tick, s: s)
        let cols = shownAggregates.map { "\($0.1) \(f1(agg[$0.0]).trimmingCharacters(in: .whitespaces))" }.joined(separator: "  ")
        print(String(format: "t=%02d  %@  | valid %3d/%3d | gated %@%@ | %.1f ms", tick, cols, frame.values.count,
                     request.sensorIDs.count, gated, frame.isPostWake ? " | postWake" : "", millis(cost)))
    }

    static func waitForNextTick(_ clock: ContinuousClock, next: inout ContinuousClock.Instant, tick: Int, seconds: Int) async {
        next = next.advanced(by: .seconds(1))
        if tick + 1 < seconds { try? await clock.sleep(until: next, tolerance: .milliseconds(50)) }
    }

    static func printWatchSummary(_ state: WatchState, seconds: Int) {
        print("# summary over \(seconds) ticks")
        for k in AggregateKind.allCases {
            guard let v = state.aggSeries[k], !v.isEmpty else { print("AGG \(k.rawValue): no value"); continue }
            print(String(format: "AGG %-13@ min %5.1f  max %5.1f  mean %5.1f  present %d/%d", k.rawValue as NSString,
                         v.min()!, v.max()!, v.reduce(0, +) / Double(v.count), v.count, seconds))
        }
        print("# gated ticks: \(state.gatedTicks)/\(seconds); clusters seen gated: \(state.gatedSeen.isEmpty ? "none" : state.gatedSeen.sorted().joined(separator: " "))")
        print("# aggregate values equal to 0 or 40.0: \(state.violations.isEmpty ? "none (OK)" : state.violations.joined(separator: ", "))")
    }

    static func printPostWakeSummary(_ state: WatchState) {
        print("# post-wake ticks: \(state.postWakeTicks); valid P-core/P-fabric/cluster-aggregate values during them: \(state.postWakeValidP)")
    }

    static func printPerKeyDeltas(_ state: WatchState, s: Session, request: SampleRequest, seconds: Int) {
        print("# per-key deltas (valid samples only): id  min  max  Δ  first→last  valid/ticks")
        for x in s.inventory.sensors where request.sensorIDs.contains(x.id) {
            guard let e = state.keySeries[x.id] else { print("\(x.id)\tno valid sample"); continue }
            print(String(format: "%@\t%6.2f\t%6.2f\tΔ %5.2f\t%6.2f→%6.2f\t%d/%d\t%@", x.id.description, e.min, e.max,
                         e.max - e.min, e.first, e.last, e.valid, seconds, x.name(preferRussian: false)))
        }
    }

    // MARK: resolve (dry run)

    struct ResolveInput {
        let catalog: SensorCatalog
        let name: String
        let heuristic: Bool
        let keyCount: Int
        let hidCount: Int
        let appleSilicon: Bool
    }

    static func resolve(_ args: [String]) {
        guard args.count >= 2 else { print("usage: thermik-probe sensors resolve <db> KEY[,KEY…] [--hid P1,P2…]"); return }
        guard let input = resolveInput(args) else { return }
        print("# dry run: \(input.heuristic ? "heuristics(\(input.name))" : "\(input.name).json") against \(input.keyCount) SMC keys + \(input.hidCount) HID products → catalog=\(status(input.catalog.status))")
        printResolvedSensors(input.catalog)
        printResolvedHeadlines(input.catalog)
        print("SAFETY \(input.catalog.safetySet.map(\.key).joined(separator: " "))")
        printResolveFilter(appleSilicon: input.appleSilicon)
    }

    static func resolveInput(_ args: [String]) -> ResolveInput? {
        let kind = resolveKind(args[0])
        let db = kind.heuristic ? nil : SensorCatalog.loadDatabase(platform: kind.name)
        guard kind.heuristic || db != nil else { print("no bundled DB named \(kind.name).json"); return nil }
        let keys = args[1].split(separator: ",").map(String.init)
        let hid = hidProducts(args)
        let appleSilicon = kind.name != "intel"
        let hw = resolveHardware(name: kind.name, appleSilicon: appleSilicon, keys: keys, hid: hid)
        let catalog = SensorCatalog(database: db, hardware: hw)
        return ResolveInput(catalog: catalog, name: kind.name, heuristic: kind.heuristic,
                            keyCount: keys.count, hidCount: hid.count, appleSilicon: appleSilicon)
    }

    static func resolveKind(_ arg: String) -> (heuristic: Bool, name: String) {
        let heuristic = arg.hasPrefix("heuristic")
        return (heuristic, heuristic ? String(arg.drop { $0 != ":" }.dropFirst()) : arg)
    }

    static func hidProducts(_ args: [String]) -> [String] {
        args.firstIndex(of: "--hid").flatMap { i in i + 1 < args.count ? args[i + 1].split(separator: ",").map(String.init) : nil } ?? []
    }

    static func resolveHardware(name: String, appleSilicon: Bool, keys: [String], hid: [String]) -> SensorCatalog.Hardware {
        SensorCatalog.Hardware(platform: name, isAppleSilicon: appleSilicon,
                               smcTemperatureKeys: keys.map { ($0, appleSilicon ? "flt " : "sp78") },
                               hidProducts: Set(hid))
    }

    static func printResolvedSensors(_ catalog: SensorCatalog) {
        for x in catalog.sensors {
            print("\(x.id)\t\(x.group.rawValue)\t\(x.role.rawValue)\t\(x.isVisibleByDefault ? "visible" : "hidden")\t\(x.isHeuristic ? "heuristic" : "db")\t\(x.name(preferRussian: false))")
        }
    }

    static func printResolvedHeadlines(_ catalog: SensorCatalog) {
        for set in HeadlineSet.allCases {
            print("HEADLINE \(set.rawValue): \(catalog.headline[set]?.map(\.key).joined(separator: " ") ?? "-")")
        }
    }

    static func printResolveFilter(appleSilicon: Bool) {
        let filter = SanityFilter(appleSilicon: appleSilicon)
        let probe = SensorDescriptor(key: "TC0D", name: "probe", group: .cpuPerformance, invalidValues: nil)
        let samples: [Double] = [0, -128, 127.99609375, 40, 55.25, 131]
        print("FILTER \(appleSilicon ? "apple-silicon" : "intel") cpuPerformance: "
              + samples.map { "\($0)=\(filter.isValid($0, probe) ? "ok" : "invalid")" }.joined(separator: " "))
    }

    // MARK: discover

    static func discover(seconds: Int) async {
        let provider = makeProvider()
        let identity = ChipIdentity.read(smc: provider?.connection)
        let hid = HIDSensorReader(kind: .temperature)
        let hw = SensorCatalog.hardware(provider: provider, hidProducts: hid?.products ?? [], identity: identity, database: nil)
        let catalog = SensorCatalog(database: nil, hardware: hw)
        noteDiscovery(identity, hw: hw, catalog: catalog, provider: provider)
        let descriptors = discoveryDescriptors(catalog: catalog, hw: hw, identity: identity)
        let refined = await refineDiscovery(descriptors, seconds: seconds, provider: provider, identity: identity)
        writeDraft(catalog: catalog, identity: identity, refined: refined, seconds: seconds)
    }

    static func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func makeProvider() -> SMCSensorProvider? {
        do {
            let provider = try SMCSensorProvider()
            try provider.discover()
            return provider
        } catch {
            note("SMC unavailable: \(error)")
            return nil
        }
    }

    static func noteDiscovery(_ identity: ChipIdentity, hw: SensorCatalog.Hardware,
                              catalog: SensorCatalog, provider: SMCSensorProvider?) {
        note("# discover: platform=\(identity.platformName) chip=\(identity.chipName) model=\(identity.modelIdentifier) "
             + "smc keys=\(provider?.keyCount ?? 0) temperature candidates=\(hw.smcTemperatureKeys.count) hid products=\(hw.hidProducts.count) "
             + "heuristic sensors=\(catalog.sensors.count) (bundled DB ignored on purpose)")
    }

    /// The draft lists EVERY key (a DB also describes peak-hold / reference / unused keys so they stay hidden):
    /// the catalog's descriptors, plus heuristic ones for the keys the catalog drops as never shown.
    static func discoveryDescriptors(catalog: SensorCatalog, hw: SensorCatalog.Hardware,
                                     identity: ChipIdentity) -> [SensorDescriptor] {
        let inCatalog = Dictionary(catalog.sensors.map { ($0.descriptor.key, $0.descriptor) }, uniquingKeysWith: { a, _ in a })
        let dieFallback = identity.isAppleSilicon && !Heuristics.hasSMCDieKeys(hw.smcTemperatureKeys.map(\.key))
        var descriptors = hw.smcTemperatureKeys.map(\.key).sorted { FourCC($0) < FourCC($1) }.map {
            inCatalog[$0] ?? Heuristics.descriptor(forSMCKey: $0, appleSilicon: identity.isAppleSilicon, hasDatabase: false,
                                                   platform: identity.platformName)
        }
        descriptors += hw.hidProducts.sorted().map {
            inCatalog["hid:\($0)"] ?? Heuristics.descriptor(forHIDProduct: $0, dieFallback: dieFallback)
        }
        return descriptors
    }

    static func refineDiscovery(_ descriptors: [SensorDescriptor], seconds: Int, provider: SMCSensorProvider?,
                                identity: ChipIdentity) async -> (descriptors: [SensorDescriptor], headline: [HeadlineSet: [String]]?) {
        guard seconds > 0, let provider else { return (descriptors, nil) }
        let detectors = await sampleDetectors(descriptors, seconds: seconds, provider: provider, identity: identity)
        let refined = detectors.refine(descriptors)
        noteRoleChanges(detectors, before: descriptors, after: refined)
        let headline = Heuristics.headline(for: refined.filter { !$0.role.isNeverShown }, appleSilicon: identity.isAppleSilicon)
        return (refined, headline)
    }

    static func sampleDetectors(_ descriptors: [SensorDescriptor], seconds: Int,
                                provider: SMCSensorProvider, identity: ChipIdentity) async -> HeuristicDetectors {
        let filter = SanityFilter(appleSilicon: identity.isAppleSilicon)
        let byKey = Dictionary(descriptors.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let keys = provider.temperatureKeys.map(\.key)
        var detectors = HeuristicDetectors()
        let clock = ContinuousClock()
        var next = clock.now
        note("# sampling \(keys.count) keys at 1 Hz for \(seconds) s (light CPU/GPU load improves offset detection)")
        await runDetectorLoop(provider, keys: keys, byKey: byKey, filter: filter, seconds: seconds,
                              detectors: &detectors, clock: clock, next: &next)
        return detectors
    }

    static func runDetectorLoop(_ provider: SMCSensorProvider, keys: [FourCC], byKey: [String: SensorDescriptor],
                                filter: SanityFilter, seconds: Int, detectors: inout HeuristicDetectors,
                                clock: ContinuousClock, next: inout ContinuousClock.Instant) async {
        for i in 0..<seconds {
            let sample = readDiscoverySample(provider, keys: keys, byKey: byKey, filter: filter)
            detectors.add(sample, keys: keys.map(\.description))
            noteDetectorProgress(i, seconds: seconds)
            next = next.advanced(by: .seconds(1))
            if i + 1 < seconds { try? await clock.sleep(until: next, tolerance: .milliseconds(50)) }
        }
    }

    static func readDiscoverySample(_ provider: SMCSensorProvider, keys: [FourCC],
                                    byKey: [String: SensorDescriptor], filter: SanityFilter)
        -> [String: (bytes: [UInt8], value: Double?)] {
        var sample: [String: (bytes: [UInt8], value: Double?)] = [:]
        provider.readPass(keys) { k, v, b in
            let key = k.description
            let valid = byKey[key].map { filter.isValid(v, $0) } ?? false
            sample[key] = (b, valid ? v : nil)
        }
        return sample
    }

    static func noteDetectorProgress(_ index: Int, seconds: Int) {
        if (index + 1) % 10 == 0 { note("#   \(index + 1)/\(seconds) s") }
    }

    static func noteRoleChanges(_ detectors: HeuristicDetectors, before: [SensorDescriptor], after: [SensorDescriptor]) {
        let beforeRoles = roleCounts(before), afterRoles = roleCounts(after)
        note("# detectors over \(detectors.samples) samples: "
             + SensorRole.allCases.map { "\($0.rawValue) \(beforeRoles[$0] ?? 0)→\(afterRoles[$0] ?? 0)" }.joined(separator: ", "))
    }

    static func roleCounts(_ descriptors: [SensorDescriptor]) -> [SensorRole: Int] {
        descriptors.reduce(into: [:]) { $0[$1.role, default: 0] += 1 }
    }

    static func writeDraft(catalog: SensorCatalog, identity: ChipIdentity,
                           refined: (descriptors: [SensorDescriptor], headline: [HeadlineSet: [String]]?), seconds: Int) {
        let db = makeDraft(catalog: catalog, identity: identity, refined: refined, seconds: seconds)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            FileHandle.standardOutput.write(try enc.encode(db))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            note("encode failed: \(error)")
        }
    }

    static func makeDraft(catalog: SensorCatalog, identity: ChipIdentity,
                          refined: (descriptors: [SensorDescriptor], headline: [HeadlineSet: [String]]?), seconds: Int)
        -> ChipSensorDatabase {
        catalog.draftDatabase(
            identity: identity, descriptors: refined.descriptors, headline: refined.headline,
            note: "Heuristic draft by thermik-probe sensors discover\(seconds > 0 ? " (\(seconds) s detectors)" : "") on "
                + "\(identity.modelIdentifier). NOT verified: curate names/groups/roles, run a ≤ 60 s load test, then set verified.")
    }
}
