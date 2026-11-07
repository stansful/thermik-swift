// SensorAggregator.swift — Thermik (MIT).
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

    private struct ReadingAccumulator {
        var sum = 0.0, n = 0, sumDup = 0.0, nDup = 0, valid = 0, total = 0
        var best: (id: SensorID, value: Double)?

        var mean: Double? {
            if n > 0 { return sum / Double(n) }
            guard nDup > 0 else { return nil }
            return sumDup / Double(nDup)
        }

        var stat: GroupStat {
            GroupStat(mean: mean, max: best?.value, hottest: best?.id, valid: valid, total: total)
        }

        mutating func add(_ id: SensorID, value: Double?, role: SensorRole) {
            total += 1
            guard let value else { return }
            valid += 1
            updateBest(id, value: value)
            addToMean(value, role: role)
        }

        private mutating func addToMean(_ value: Double, role: SensorRole) {
            if role == .duplicate {
                sumDup += value
                nDup += 1
                return
            }
            sum += value
            n += 1
        }

        private mutating func updateBest(_ id: SensorID, value: Double) {
            guard let current = best else {
                best = (id, value)
                return
            }
            guard value > current.value || (value == current.value && id < current.id) else { return }
            best = (id, value)
        }
    }

    /// Headline aggregates from valid (sanitized, unsmoothed) values. Missing inputs → key absent.
    public func aggregates(_ values: [SensorID: Double], visible: Set<SensorID>) -> AggregateValues {
        var out = AggregateValues()
        addHeadline(values, to: &out)
        addVisible(values, visible: visible, to: &out)
        addSafety(values, to: &out)
        return out
    }

    private func addHeadline(_ values: [SensorID: Double], to out: inout AggregateValues) {
        let cpuAvg = Self.mean(cpu, values)
        let gpuAvg = Self.mean(gpu, values)
        addCPU(values, average: cpuAvg, to: &out)
        addGPU(values, average: gpuAvg, to: &out)
        Self.put(.socHottest, [cpuAvg, gpuAvg].compactMap { $0 }.max(), to: &out)
        Self.put(.socDie, Self.mean(soc, values), to: &out)
        Self.put(.memory, Self.mean(memory, values), to: &out)
        Self.put(.ssd, Self.mean(ssd, values), to: &out)
        Self.put(.battery, Self.mean(battery, values), to: &out)
    }

    private func addCPU(_ values: [SensorID: Double], average: Double?, to out: inout AggregateValues) {
        Self.put(.cpuAverage, average, to: &out)
        let hot = Self.max(cpuHotspot, values)
        Self.put(.cpuHottest, hot?.value, hot?.id, to: &out)
    }

    private func addGPU(_ values: [SensorID: Double], average: Double?, to out: inout AggregateValues) {
        Self.put(.gpuAverage, average, to: &out)
        let hot = Self.max(gpu, values)
        Self.put(.gpuHottest, hot?.value, hot?.id, to: &out)
    }

    private func addVisible(_ values: [SensorID: Double], visible: Set<SensorID>, to out: inout AggregateValues) {
        var acc = ReadingAccumulator()
        for id in visible {
            guard let value = values[id], let role = roles[id] else { continue }
            acc.add(id, value: value, role: role)
        }
        Self.put(.highestAll, acc.best?.value, acc.best?.id, to: &out)
        Self.put(.averageAll, acc.mean, to: &out)
    }

    private func addSafety(_ values: [SensorID: Double], to out: inout AggregateValues) {
        let top = safety.compactMap { id in values[id].map { (id: id, value: $0) } }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.id < $1.id }
        guard let hottest = top.first else { return }
        let four = top.prefix(4)
        Self.put(.safetyTop4, four.reduce(0) { $0 + $1.value } / Double(four.count), to: &out)
        Self.put(.rawHottestDie, hottest.value, hottest.id, to: &out)
    }

    private static func put(_ kind: AggregateKind, _ value: Double?, _ source: SensorID? = nil,
                            to out: inout AggregateValues) {
        guard let value, value.isFinite else { return }
        out.values[kind] = value
        if let source { out.sources[kind] = source }
    }

    /// Mean / max / hottest per display group over `visible` sensors that have a valid value.
    /// The stats describe exactly the rows the user sees: `mean` over the valid visible sensors (a mirror — role
    /// `duplicate`, shown only if the user un-hides it — is not counted twice), `max` / `hottest` over all of them,
    /// so the group header always agrees with its hottest row. `total` counts the visible sensors of the group.
    public func groupStats(_ values: [SensorID: Double], visible: Set<SensorID>) -> [DisplayGroup: GroupStat] {
        var acc: [DisplayGroup: ReadingAccumulator] = [:]
        for id in visible {
            guard let group = displayGroups[id], let role = roles[id] else { continue }
            var groupAcc = acc[group] ?? ReadingAccumulator()
            groupAcc.add(id, value: values[id], role: role)
            acc[group] = groupAcc
        }
        return acc.mapValues { $0.stat }
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
