// SensorAggregator.swift — Thermik (MIT). OWNER: Unit 1. API FROZEN.
// Pure: computes AggregateValues and per-DisplayGroup stats from one frame of VALID raw values (§2.5.4/§2.5.5).
//
// Formulas (SPEC §2.5.5; the Intel chains of §3.4 are resolved into the headline sets by SensorCatalog):
//   cpuAverage     mean of valid headline.cpu (24 calibrated P + 2 E on M4 Max; the E-cluster is never gated)
//   cpuHottest     max of valid headline.cpuHotspot (Tpx1, Tpx9, Te06, Te0T), source = argmax
//   gpuAverage/Hot mean / max of valid headline.gpu
//   socHottest     max(cpuAverage, gpuAverage)
//   socDie         headline.soc (TCMb)
//   highestAll     max over visible valid sensors, source = argmax
//   averageAll     mean over visible valid sensors (mirrors — role `duplicate` — are not counted twice)
//   memory/ssd/battery  mean of valid headline.memory / .ssd / .battery
//   safetyTop4     mean of the 4 hottest valid values of the safety set (fewer if fewer are valid)
//   rawHottestDie  max of the safety set, source = argmax
// Missing inputs → the kind is absent (never 0). Values are unsmoothed; SensorStore smooths them (§2.5.6).
// Cost (M4 Max, ≈ 290 valid values): aggregates + groupStats ≈ 0.02 ms in Release, 0.1 ms in Debug (`sensors bench`).
import Foundation

public struct SensorAggregator: Sendable {
    public let inventory: SensorInventory
    private let roles: [SensorID: SensorRole]
    private let displayGroups: [SensorID: DisplayGroup]
    private let cpu: [SensorID], cpuHotspot: [SensorID], gpu: [SensorID], soc: [SensorID]
    private let memory: [SensorID], ssd: [SensorID], battery: [SensorID], safety: [SensorID]

    public init(inventory: SensorInventory) {
        self.inventory = inventory
        roles = Dictionary(inventory.sensors.map { ($0.id, $0.role) }, uniquingKeysWith: { a, _ in a })
        displayGroups = Dictionary(inventory.sensors.map { ($0.id, $0.displayGroup) }, uniquingKeysWith: { a, _ in a })
        let h = inventory.headline
        cpu = h[.cpu] ?? []; cpuHotspot = h[.cpuHotspot] ?? []; gpu = h[.gpu] ?? []; soc = h[.soc] ?? []
        memory = h[.memory] ?? []; ssd = h[.ssd] ?? []; battery = h[.battery] ?? []
        safety = inventory.safetySet
    }

    /// Headline aggregates from valid (sanitized, unsmoothed) values. Missing inputs → key absent.
    public func aggregates(_ values: [SensorID: Double], visible: Set<SensorID>) -> AggregateValues {
        var out = AggregateValues()
        func put(_ k: AggregateKind, _ v: Double?, _ source: SensorID? = nil) {
            guard let v, v.isFinite else { return }
            out.values[k] = v
            if let source { out.sources[k] = source }
        }
        let cpuAvg = Self.mean(cpu, values)
        let gpuAvg = Self.mean(gpu, values)
        put(.cpuAverage, cpuAvg)
        let hot = Self.max(cpuHotspot, values); put(.cpuHottest, hot?.value, hot?.id)
        put(.gpuAverage, gpuAvg)
        let gHot = Self.max(gpu, values); put(.gpuHottest, gHot?.value, gHot?.id)
        put(.socHottest, [cpuAvg, gpuAvg].compactMap { $0 }.max())
        put(.socDie, Self.mean(soc, values))
        put(.memory, Self.mean(memory, values))
        put(.ssd, Self.mean(ssd, values))
        put(.battery, Self.mean(battery, values))

        // Visible sensors (any order): one pass for both whole-Mac figures.
        var best: (id: SensorID, value: Double)?
        var sum = 0.0, n = 0, sumDup = 0.0, nDup = 0
        for id in visible {
            guard let v = values[id], let role = roles[id] else { continue }
            if let b = best { if v > b.value || (v == b.value && id < b.id) { best = (id, v) } } else { best = (id, v) }
            if role != .duplicate { sum += v; n += 1 } else { sumDup += v; nDup += 1 }
        }
        put(.highestAll, best?.value, best?.id)
        put(.averageAll, n > 0 ? sum / Double(n) : (nDup > 0 ? sumDup / Double(nDup) : nil))

        // Safety set: the engine's critical inputs.
        var top: [(id: SensorID, value: Double)] = []
        top.reserveCapacity(safety.count)
        for id in safety { if let v = values[id] { top.append((id, v)) } }
        if !top.isEmpty {
            top.sort { $0.value != $1.value ? $0.value > $1.value : $0.id < $1.id }
            let four = top.prefix(4)
            put(.safetyTop4, four.reduce(0) { $0 + $1.value } / Double(four.count))
            put(.rawHottestDie, top[0].value, top[0].id)
        }
        return out
    }

    /// Mean / max / hottest per display group over `visible` sensors that have a valid value.
    /// The stats describe exactly the rows the user sees: `mean` over the valid visible sensors (a mirror — role
    /// `duplicate`, shown only if the user un-hides it — is not counted twice), `max` / `hottest` over all of them,
    /// so the group header always agrees with its hottest row. `total` counts the visible sensors of the group.
    public func groupStats(_ values: [SensorID: Double], visible: Set<SensorID>) -> [DisplayGroup: GroupStat] {
        struct Acc { var sum = 0.0, n = 0, sumDup = 0.0, nDup = 0, valid = 0, total = 0; var best: (SensorID, Double)? }
        var acc: [DisplayGroup: Acc] = [:]
        for id in visible {
            guard let g = displayGroups[id], let role = roles[id] else { continue }
            var a = acc[g] ?? Acc()
            a.total += 1
            if let v = values[id] {
                a.valid += 1
                if role != .duplicate { a.sum += v; a.n += 1 } else { a.sumDup += v; a.nDup += 1 }
                if let b = a.best { if v > b.1 || (v == b.1 && id < b.0) { a.best = (id, v) } } else { a.best = (id, v) }
            }
            acc[g] = a
        }
        return acc.mapValues { a in
            let mean = a.n > 0 ? a.sum / Double(a.n) : (a.nDup > 0 ? a.sumDup / Double(a.nDup) : nil)
            return GroupStat(mean: mean, max: a.best?.1, hottest: a.best?.0, valid: a.valid, total: a.total)
        }
    }

    // MARK: Helpers

    private static func mean(_ ids: [SensorID], _ values: [SensorID: Double]) -> Double? {
        var sum = 0.0, n = 0
        for id in ids { if let v = values[id] { sum += v; n += 1 } }
        return n > 0 ? sum / Double(n) : nil
    }

    /// Max with a deterministic tie-break (lowest id) so the "Hottest · …" source does not flicker.
    private static func max(_ ids: [SensorID], _ values: [SensorID: Double]) -> (id: SensorID, value: Double)? {
        var best: (id: SensorID, value: Double)?
        for id in ids {
            guard let v = values[id] else { continue }
            if let b = best { if v > b.value || (v == b.value && id < b.id) { best = (id, v) } } else { best = (id, v) }
        }
        return best
    }
}
