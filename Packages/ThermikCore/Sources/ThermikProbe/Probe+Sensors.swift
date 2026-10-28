// Probe+Sensors.swift — OWNER: Unit 1. `thermik-probe sensors …` (READ-ONLY: SMC reads + HID events, no writes).
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
        let sub = args.first ?? "groups"
        let rest = Array(args.dropFirst())
        let seconds = rest.compactMap { Int($0) }.first
        switch sub {
        case "groups":   await SensorProbe.groups()
        case "snapshot": await SensorProbe.snapshot()
        case "bench":    await SensorProbe.bench()
        case "watch":    await SensorProbe.watch(seconds: max(1, seconds ?? 20), perKey: rest.contains("--keys"),
                                                 simulateWake: rest.contains("--wake"))
        case "discover": await SensorProbe.discover(seconds: max(0, seconds ?? 0))
        case "resolve":  SensorProbe.resolve(rest)
        default:
            print("usage: thermik-probe sensors groups | snapshot | bench | watch [seconds] [--keys] [--wake] | discover [seconds] | resolve <db> KEY,… [--hid P,…]")
        }
    }
}

private enum SensorProbe {

    // MARK: Shared

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
        let clock = ContinuousClock()
        let t0 = clock.now
        let frame = await s.sampler.sample(SampleRequest(sensorIDs: s.popoverRequest))
        let passTime = clock.now - t0
        let visible = s.visible
        for g in SensorGroup.allCases {
            let items = s.inventory.sensors.filter { $0.group == g && visible.contains($0.id) }
            guard !items.isEmpty else { continue }
            let vals = items.compactMap { frame.values[$0.id] }
            let mean = vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
            print(String(format: "== %-15@ valid %2d/%2d  avg %@  max %@", g.rawValue as NSString, vals.count, items.count,
                         f1(mean), f1(vals.max())))
            for x in items {
                let v = frame.values[x.id]
                let state = v != nil ? "" : (frame.gated.contains(x.id) ? "  (gated)" : "  (invalid, raw \(f1(frame.raw[x.id]).trimmingCharacters(in: .whitespaces)))")
                print("     \(x.id.key)  \(v.map { String(format: "%5.1f °C", $0) } ?? "   —   ")  \(x.role.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))  "
                      + "\(x.name(preferRussian: false))  /  \(x.name(preferRussian: true))\(state)")
            }
        }
        let stats = s.aggregator.groupStats(frame.values, visible: visible)
        for g in DisplayGroup.allCases {
            guard let st = stats[g] else { continue }
            print(String(format: "GROUP %-9@ mean %@  max %@  hottest %@  (%d/%d valid)", g.rawValue as NSString, f1(st.mean),
                         f1(st.max), (st.hottest?.key ?? "-") as NSString, st.valid, st.total))
        }
        let agg = s.aggregator.aggregates(frame.values, visible: visible)
        let inputs: [AggregateKind: [SensorID]] = [
            .cpuAverage: s.inventory.headline[.cpu] ?? [], .cpuHottest: s.inventory.headline[.cpuHotspot] ?? [],
            .gpuAverage: s.inventory.headline[.gpu] ?? [], .gpuHottest: s.inventory.headline[.gpu] ?? [],
            .socDie: s.inventory.headline[.soc] ?? [], .memory: s.inventory.headline[.memory] ?? [],
            .ssd: s.inventory.headline[.ssd] ?? [], .battery: s.inventory.headline[.battery] ?? [],
            .safetyTop4: s.inventory.safetySet, .rawHottestDie: s.inventory.safetySet,
            .highestAll: Array(visible), .averageAll: Array(visible),
        ]
        for k in AggregateKind.allCases {
            var line = String(format: "HEADLINE %-13@ %@ °C", k.rawValue as NSString, f1(agg[k]))
            if let ids = inputs[k] { line += "  (\(ids.filter { frame.values[$0] != nil }.count)/\(ids.count) valid)" }
            if let src = agg.sources[k] { line += "  source=\(src.key)" }
            print(line)
        }
        print(powerLine(frame.power))
        print(fanLine(frame.fans))
        print("# gated: \(gatedSummary(frame.gated, s))  postWake=\(frame.isPostWake)")
        print("# timings: start \(ms(await s.sampler.startDuration)), read pass (\(s.popoverRequest.count) keys + fans + power) \(ms(passTime))")
    }

    // MARK: snapshot

    static func snapshot() async {
        guard let s = await open() else { return }
        await header(s)
        let frame = await s.sampler.sample(SampleRequest(sensorIDs: s.inventory.sensors.map(\.id)))
        print("# id\traw\tstate\tgroup\trole\tvisibility\ttype\tname\tnameRu")
        for x in s.inventory.sensors {
            let state = frame.values[x.id] != nil ? "ok" : (frame.gated.contains(x.id) ? "gated" : (frame.raw[x.id] == nil ? "unread" : "INVALID"))
            print("\(x.id)\t\(f2(frame.raw[x.id]))\t\(state)\t\(clusterLabel(x))\t\(x.role.rawValue)\t"
                  + "\(x.isVisibleByDefault ? "visible" : "hidden")\t\(x.smcType ?? "hid")\t\(x.name(preferRussian: false))\t\(x.name(preferRussian: true))")
        }
        let keys = Set(s.inventory.sensors.map(\.id.key))
        let neverShown = s.inventory.sensors.filter { $0.role.isNeverShown }.count
        let peak = ["Tf06", "Tf16", "Tf26", "Tf36", "Tf46"].filter { keys.contains($0) }
        print("# never-shown roles in inventory: \(neverShown); Tf?6 peak-hold keys present: \(peak.isEmpty ? "none" : peak.joined(separator: " "))")
        print("# valid \(frame.values.count) / read \(frame.raw.count) / inventory \(s.inventory.sensors.count); gated \(gatedSummary(frame.gated, s))")
        print("# HID service instances")
        for h in await s.sampler.hidInstances() {
            print(String(format: "hid:%@\t%8.3f\tloc=%@\tregistry=0x%llx", h.product, h.value, h.location, h.registryID))
        }
        print(powerLine(frame.power))
        print(fanLine(frame.fans))
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

    static func bench() async {
        print("# READ-ONLY timing benchmark. Other builds may be running in parallel: numbers can be noisy.")
        let clock = ContinuousClock()
        var start = Stats()
        var last: Session?
        for _ in 0..<5 {
            let t0 = clock.now
            guard let s = await open() else { return }
            start.add(clock.now - t0)
            last = s
        }
        guard let s = last else { return }
        await header(s)
        let visibleIDs = s.inventory.sensors.filter { $0.isVisibleByDefault && $0.id.source == .smc }.map(\.id)
        let headline = s.headlineAndSafety.filter { $0.source == .smc }
        let all = s.inventory.sensors.filter { $0.id.source == .smc }.map(\.id)
        let hidIDs = s.inventory.sensors.filter { $0.id.source == .hid }.map(\.id)

        func run(_ ids: [SensorID], fans: Bool, power: Bool, n: Int) async -> Stats {
            var st = Stats()
            for _ in 0..<n {
                let t0 = clock.now
                _ = await s.sampler.sample(SampleRequest(sensorIDs: ids, includeFans: fans, includePower: power))
                st.add(clock.now - t0)
            }
            return st
        }
        let vis = await run(visibleIDs, fans: false, power: false, n: 30)
        let visFull = await run(visibleIDs, fans: true, power: true, n: 30)
        let head = await run(headline, fans: false, power: false, n: 30)
        let headFull = await run(headline, fans: true, power: true, n: 30)
        let full = await run(all, fans: false, power: false, n: 10)
        let fansOnly = await run([], fans: true, power: false, n: 30)

        // HID: a fresh sampler per pass, so each pass really reads (the sampler caches HID values for 5 s).
        var hid = Stats()
        if !hidIDs.isEmpty {
            for _ in 0..<3 {
                guard let fresh = await open() else { break }
                let t0 = clock.now
                _ = await fresh.sampler.sample(SampleRequest(sensorIDs: hidIDs, includeFans: false, includePower: false))
                hid.add(clock.now - t0)
            }
        }
        // Aggregation on the main-actor side (SensorStore.consume): aggregates + groupStats on a full frame.
        let frame = await s.sampler.sample(SampleRequest(sensorIDs: s.inventory.sensors.map(\.id)))
        let visible = s.visible
        var agg = Stats()
        for _ in 0..<200 {
            let t0 = clock.now
            _ = s.aggregator.aggregates(frame.values, visible: visible)
            _ = s.aggregator.groupStats(frame.values, visible: visible)
            agg.add(clock.now - t0)
        }

        print("start() fresh sampler (SMC open + #KEY + catalog + HID + fans) \(start.line)")
        print("visible pass        (\(visibleIDs.count) SMC keys)                \(vis.line)")
        print("visible pass + fans + power                    \(visFull.line)")
        print("headline+safety pass (\(headline.count) SMC keys)              \(head.line)")
        print("headline+safety + fans + power                 \(headFull.line)")
        print("full inventory pass (\(all.count) SMC keys)              \(full.line)")
        print("fans snapshot only                             \(fansOnly.line)")
        print("HID pass            (\(hidIDs.count) products, uncached)         \(hid.line)")
        print("aggregates+groupStats (\(frame.values.count) values)             \(agg.line)")
        func verdict(_ name: String, _ v: Double, _ budget: Double) {
            print(String(format: "BUDGET %-22@ %7.2f ms ≤ %5.1f ms  %@", name as NSString, v, budget, v <= budget ? "PASS" : "MISS"))
        }
        verdict("start()", start.median, 150)
        verdict("visible pass", vis.median, 20)
        verdict("headline+safety pass", head.median, 10)
    }

    // MARK: watch

    static func watch(seconds: Int, perKey: Bool, simulateWake: Bool) async {
        guard let s = await open() else { return }
        await header(s)
        if simulateWake { await s.sampler.didWake() }
        var postWakeTicks = 0, postWakeValidP = 0
        let request = SampleRequest(sensorIDs: s.popoverRequest)
        let visible = s.visible
        let clock = ContinuousClock()
        var next = clock.now
        var violations: [String] = []
        var gatedTicks = 0
        var gatedSeen = Set<String>()
        var aggSeries: [AggregateKind: [Double]] = [:]
        var keySeries: [SensorID: (min: Double, max: Double, first: Double, last: Double, valid: Int)] = [:]
        let shown: [(AggregateKind, String)] = [(.cpuAverage, "cpu"), (.cpuHottest, "cpuHot"), (.gpuAverage, "gpu"),
                                                (.gpuHottest, "gpuHot"), (.socDie, "die"), (.memory, "mem"), (.ssd, "ssd"),
                                                (.battery, "bat"), (.safetyTop4, "top4"), (.rawHottestDie, "rawHot"),
                                                (.highestAll, "high")]
        print("# \(seconds) s at 1 Hz, request = visible ∪ headline ∪ safety (\(request.sensorIDs.count) ids) + fans + power")
        for tick in 0..<seconds {
            let t0 = clock.now
            let frame = await s.sampler.sample(request)
            let cost = clock.now - t0
            let agg = s.aggregator.aggregates(frame.values, visible: visible)
            for k in AggregateKind.allCases {
                guard let v = agg[k] else { continue }
                aggSeries[k, default: []].append(v)
                if v == 0 || v == 40.0 { violations.append("t=\(tick) \(k.rawValue)=\(v)") }
            }
            for (id, v) in frame.values {
                if var e = keySeries[id] { e.min = min(e.min, v); e.max = max(e.max, v); e.last = v; e.valid += 1; keySeries[id] = e }
                else { keySeries[id] = (v, v, v, v, 1) }
            }
            if frame.isPostWake {
                postWakeTicks += 1
                postWakeValidP += frame.values.keys.filter { [.cpuPerformance, .cpuFabric, .cpuAggregate].contains(s.byID[$0]?.group) }.count
            }
            let gated = gatedSummary(frame.gated, s)
            if !frame.gated.isEmpty { gatedTicks += 1; gatedSeen.formUnion(gated.split(separator: " ").map { String($0.prefix { $0 != "(" }) }) }
            let cols = shown.map { "\($0.1) \(f1(agg[$0.0]).trimmingCharacters(in: .whitespaces))" }.joined(separator: "  ")
            print(String(format: "t=%02d  %@  | valid %3d/%3d | gated %@%@ | %.1f ms", tick, cols, frame.values.count,
                         request.sensorIDs.count, gated, frame.isPostWake ? " | postWake" : "", millis(cost)))
            next = next.advanced(by: .seconds(1))
            if tick + 1 < seconds { try? await clock.sleep(until: next, tolerance: .milliseconds(50)) }
        }
        print("# summary over \(seconds) ticks")
        for k in AggregateKind.allCases {
            guard let v = aggSeries[k], !v.isEmpty else { print("AGG \(k.rawValue): no value"); continue }
            print(String(format: "AGG %-13@ min %5.1f  max %5.1f  mean %5.1f  present %d/%d", k.rawValue as NSString,
                         v.min()!, v.max()!, v.reduce(0, +) / Double(v.count), v.count, seconds))
        }
        print("# gated ticks: \(gatedTicks)/\(seconds); clusters seen gated: \(gatedSeen.isEmpty ? "none" : gatedSeen.sorted().joined(separator: " "))")
        print("# aggregate values equal to 0 or 40.0: \(violations.isEmpty ? "none (OK)" : violations.joined(separator: ", "))")
        if simulateWake {
            print("# post-wake ticks: \(postWakeTicks); valid P-core/P-fabric/cluster-aggregate values during them: \(postWakeValidP)")
        }
        if perKey || seconds >= 60 {
            print("# per-key deltas (valid samples only): id  min  max  Δ  first→last  valid/ticks")
            for x in s.inventory.sensors where request.sensorIDs.contains(x.id) {
                guard let e = keySeries[x.id] else { print("\(x.id)\tno valid sample"); continue }
                print(String(format: "%@\t%6.2f\t%6.2f\tΔ %5.2f\t%6.2f→%6.2f\t%d/%d\t%@", x.id.description, e.min, e.max,
                             e.max - e.min, e.first, e.last, e.valid, seconds, x.name(preferRussian: false)))
            }
        }
    }

    // MARK: resolve (dry run)

    static func resolve(_ args: [String]) {
        guard args.count >= 2 else { print("usage: thermik-probe sensors resolve <db> KEY[,KEY…] [--hid P1,P2…]"); return }
        let heuristic = args[0].hasPrefix("heuristic")
        let name = heuristic ? String(args[0].drop { $0 != ":" }.dropFirst()) : args[0]
        let db = heuristic ? nil : SensorCatalog.loadDatabase(platform: name)
        guard heuristic || db != nil else { print("no bundled DB named \(name).json"); return }
        let keys = args[1].split(separator: ",").map(String.init)
        let hidList = args.firstIndex(of: "--hid").flatMap { i in i + 1 < args.count ? args[i + 1].split(separator: ",").map(String.init) : nil } ?? []
        let appleSilicon = name != "intel"
        let hw = SensorCatalog.Hardware(platform: name, isAppleSilicon: appleSilicon,
                                        smcTemperatureKeys: keys.map { ($0, appleSilicon ? "flt " : "sp78") },
                                        hidProducts: Set(hidList))
        let c = SensorCatalog(database: db, hardware: hw)
        print("# dry run: \(heuristic ? "heuristics(\(name))" : "\(name).json") against \(keys.count) SMC keys + \(hidList.count) HID products → catalog=\(status(c.status))")
        for x in c.sensors {
            print("\(x.id)\t\(x.group.rawValue)\t\(x.role.rawValue)\t\(x.isVisibleByDefault ? "visible" : "hidden")\t\(x.isHeuristic ? "heuristic" : "db")\t\(x.name(preferRussian: false))")
        }
        for set in HeadlineSet.allCases {
            print("HEADLINE \(set.rawValue): \(c.headline[set]?.map(\.key).joined(separator: " ") ?? "-")")
        }
        print("SAFETY \(c.safetySet.map(\.key).joined(separator: " "))")
        let filter = SanityFilter(appleSilicon: appleSilicon)
        let probe = SensorDescriptor(key: "TC0D", name: "probe", group: .cpuPerformance, invalidValues: nil)
        let samples: [Double] = [0, -128, 127.99609375, 40, 55.25, 131]
        print("FILTER \(appleSilicon ? "apple-silicon" : "intel") cpuPerformance: "
              + samples.map { "\($0)=\(filter.isValid($0, probe) ? "ok" : "invalid")" }.joined(separator: " "))
    }

    // MARK: discover

    static func discover(seconds: Int) async {
        func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        let provider: SMCSensorProvider?
        do {
            let p = try SMCSensorProvider()
            try p.discover()
            provider = p
        } catch {
            note("SMC unavailable: \(error)")
            provider = nil
        }
        let identity = ChipIdentity.read(smc: provider?.connection)
        let hid = HIDSensorReader(kind: .temperature)
        let hw = SensorCatalog.hardware(provider: provider, hidProducts: hid?.products ?? [], identity: identity, database: nil)
        let catalog = SensorCatalog(database: nil, hardware: hw)
        note("# discover: platform=\(identity.platformName) chip=\(identity.chipName) model=\(identity.modelIdentifier) "
             + "smc keys=\(provider?.keyCount ?? 0) temperature candidates=\(hw.smcTemperatureKeys.count) hid products=\(hw.hidProducts.count) "
             + "heuristic sensors=\(catalog.sensors.count) (bundled DB ignored on purpose)")

        // The draft lists EVERY key (a DB also describes peak-hold / reference / unused keys so they stay hidden):
        // the catalog's descriptors, plus heuristic ones for the keys the catalog drops as never shown.
        let inCatalog = Dictionary(catalog.sensors.map { ($0.descriptor.key, $0.descriptor) }, uniquingKeysWith: { a, _ in a })
        let dieFallback = identity.isAppleSilicon && !Heuristics.hasSMCDieKeys(hw.smcTemperatureKeys.map(\.key))
        var descriptors = hw.smcTemperatureKeys.map(\.key).sorted { FourCC($0) < FourCC($1) }.map {
            inCatalog[$0] ?? Heuristics.descriptor(forSMCKey: $0, appleSilicon: identity.isAppleSilicon, hasDatabase: false,
                                                   platform: identity.platformName)
        }
        descriptors += hw.hidProducts.sorted().map {
            inCatalog["hid:\($0)"] ?? Heuristics.descriptor(forHIDProduct: $0, dieFallback: dieFallback)
        }
        var headline: [HeadlineSet: [String]]? = nil
        if seconds > 0, let provider {
            let filter = SanityFilter(appleSilicon: identity.isAppleSilicon)
            let byKey = Dictionary(descriptors.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let keys = provider.temperatureKeys.map(\.key)
            var detectors = HeuristicDetectors()
            let clock = ContinuousClock()
            var next = clock.now
            note("# sampling \(keys.count) keys at 1 Hz for \(seconds) s (light CPU/GPU load improves offset detection)")
            for i in 0..<seconds {
                var sample: [String: (bytes: [UInt8], value: Double?)] = [:]
                provider.readPass(keys) { k, v, b in
                    let key = k.description
                    let valid = byKey[key].map { filter.isValid(v, $0) } ?? false
                    sample[key] = (b, valid ? v : nil)
                }
                detectors.add(sample, keys: keys.map(\.description))
                if (i + 1) % 10 == 0 { note("#   \(i + 1)/\(seconds) s") }
                next = next.advanced(by: .seconds(1))
                if i + 1 < seconds { try? await clock.sleep(until: next, tolerance: .milliseconds(50)) }
            }
            let refined = detectors.refine(descriptors)
            func roles(_ d: [SensorDescriptor]) -> [SensorRole: Int] { d.reduce(into: [:]) { $0[$1.role, default: 0] += 1 } }
            let before = roles(descriptors), after = roles(refined)
            note("# detectors over \(detectors.samples) samples: " + SensorRole.allCases.map { "\($0.rawValue) \(before[$0] ?? 0)→\(after[$0] ?? 0)" }.joined(separator: ", "))
            descriptors = refined
            headline = Heuristics.headline(for: descriptors.filter { !$0.role.isNeverShown }, appleSilicon: identity.isAppleSilicon)
        }
        let db = catalog.draftDatabase(
            identity: identity, descriptors: descriptors, headline: headline,
            note: "Heuristic draft by thermik-probe sensors discover\(seconds > 0 ? " (\(seconds) s detectors)" : "") on "
                + "\(identity.modelIdentifier). NOT verified: curate names/groups/roles, run a ≤ 60 s load test, then set verified.")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            FileHandle.standardOutput.write(try enc.encode(db))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            note("encode failed: \(error)")
        }
    }
}
