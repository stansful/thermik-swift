// HistoryStore.swift — Thermik (MIT). Created by Unit 0; OWNER: Unit 5 (tiers: raw 15 min, 10 s buckets 24 h). API FROZEN.
// In-memory only (SPEC §2.8; on-disk history is P2). Two tiers per series:
//   raw      every recorded tick (Sample, 16 B), the newest 900 (= 15 min at 1 s)
//   buckets  10 s min/avg/max, 24 h (8 640) for aggregates, fans, power, usage, pressure and pinned sensors,
//            6 h (2 160) for other sensors
// Rings grow on demand, so memory follows the actual history (≈ 10–13 MB after 24 h with every sensor recorded).
// Gaps are real: a gated or unsampled sensor gets no sample, never a 0. Charts split a line where Δt exceeds
// 3 × the median spacing (`HistoryStore.segments(_:)`).
import Foundation
import Observation
import ThermikCore

@MainActor @Observable final class HistoryStore: TickConsumer {
    /// Increments once per appended tick: charts read it to refresh (cheap observation hook).
    private(set) var revision: UInt64 = 0
    /// Increment at most every 5 s and every 30 s: sparklines and long chart windows cannot show a 1 s step, so they
    /// redraw at these rates instead of on every tick (`chartRevision(for:)`).
    private(set) var sparklineRevision: UInt64 = 0
    private(set) var longWindowRevision: UInt64 = 0
    @ObservationIgnored private var sparklineBumpedAt = Date.distantPast
    @ObservationIgnored private var longWindowBumpedAt = Date.distantPast
    @ObservationIgnored private weak var sensors: SensorStore?
    @ObservationIgnored private weak var fans: FanStore?
    @ObservationIgnored private weak var system: SystemStore?
    @ObservationIgnored private var series: [SeriesID: SeriesHistory] = [:]
    @ObservationIgnored private var sparklineCache: [SparklineKey: [Float]] = [:]
    @ObservationIgnored private var sparklineCacheRevision: UInt64 = 0

    enum Tier {
        static let rawRetention: TimeInterval = 900
        static let rawCapacity = 900
        static let bucketSeconds: TimeInterval = 10
        static let longBucketCapacity = 8_640              // 24 h
        static let shortBucketCapacity = 2_160             // 6 h
        static let sparklineWindow: TimeInterval = 300     // 5 min
        static let sparklineRefresh: TimeInterval = 5      // ≈ one sparkline point (300 s / 54 pt)
        static let longWindowRefresh: TimeInterval = 30    // well under one plotted column of a 6 h / 24 h chart
    }

    private struct SparklineKey: Hashable { let id: SeriesID; let points: Int }

    init(sensors: SensorStore) { self.sensors = sensors }
    /// Wired by AppEnvironment (fan rpm/target series; cpu/gpu usage and pressure series).
    func attach(fans: FanStore, system: SystemStore) { self.fans = fans; self.system = system }

    // MARK: Recording

    /// Runs after SensorStore and SystemStore (SPEC §2.3.3): sensor and aggregate values are this tick's smoothed
    /// ones. Fan values come from the frame itself (FanStore consumes after this store).
    func consume(_ tick: Tick) {
        let t = tick.date
        if let sensors {
            for id in tick.sensors.values.keys {                     // valid this tick only: gaps stay gaps
                guard let live = sensors.sensor(id), let v = live.value else { continue }
                record(.sensor(id), v, at: t, long: live.isPinned)
            }
            for (kind, v) in sensors.aggregates.values { record(.aggregate(kind), v, at: t, long: true) }
        }
        if let fanState = tick.sensors.fans {
            for f in fanState.fans {
                record(.fanRPM(f.index), f.actualRPM, at: t, long: true)
                record(.fanTarget(f.index), f.targetRPM, at: t, long: true)
            }
        }
        let p = tick.sensors.power
        if let w = p.systemTotalW { record(.power(.systemTotal), w, at: t, long: true) }
        if let w = p.dcInW { record(.power(.dcIn), w, at: t, long: true) }
        if let w = p.batteryW { record(.power(.battery), w, at: t, long: true) }
        if let w = p.socW { record(.power(.soc), w, at: t, long: true) }
        if let s = tick.system {
            if s.cpuLoad != nil, let u = s.cpuTotalPercent { record(.cpuUsage, u, at: t, long: true) }
            if let g = s.gpu?.devicePercent { record(.gpuUsage, Double(g), at: t, long: true) }
            if let w = s.soc?.power.cpuW { record(.power(.cpu), w, at: t, long: true) }
            if let w = s.soc?.power.gpuW { record(.power(.gpu), w, at: t, long: true) }
            record(.pressure, Double(s.pressure.rawValue), at: t, long: true)
        }
        revision &+= 1
        let sinceSparkline = t.timeIntervalSince(sparklineBumpedAt)
        if sinceSparkline >= Tier.sparklineRefresh || sinceSparkline < 0 { sparklineRevision &+= 1; sparklineBumpedAt = t }
        let sinceLong = t.timeIntervalSince(longWindowBumpedAt)
        if sinceLong >= Tier.longWindowRefresh || sinceLong < 0 { longWindowRevision &+= 1; longWindowBumpedAt = t }
    }

    /// Refresh hook for a chart of `window`: every tick for 5 min, every 5 s for 15 min and 1 h (≥ one plotted point),
    /// every 30 s for 6 h / 24 h.
    func chartRevision(for window: HistoryWindow) -> UInt64 {
        switch window {
        case .m5: revision
        case .m15, .h1: sparklineRevision
        case .h6, .h24: longWindowRevision
        }
    }

    private func record(_ id: SeriesID, _ value: Double, at t: Date, long: Bool) {
        guard value.isFinite else { return }
        let capacity = long ? Tier.longBucketCapacity : Tier.shortBucketCapacity
        series[id, default: SeriesHistory(bucketCapacity: capacity)].append(Float(value), at: t, bucketCapacity: capacity)
    }

    // MARK: Queries

    /// Time-ordered samples within `window`, LTTB-downsampled to ≤ maxPoints. Windows ≤ 15 min read the raw tier;
    /// longer ones read bucket averages, then the raw tier for its span.
    func samples(_ id: SeriesID, window: HistoryWindow, maxPoints: Int) -> [Sample] {
        guard maxPoints > 0, let s = series[id] else { return [] }
        return Self.downsample(merged(s, window: window), maxPoints: maxPoints)
    }

    /// Min/avg/max buckets (6 h / 24 h views), ≤ columns.
    func buckets(_ id: SeriesID, window: HistoryWindow, columns: Int) -> [Bucket] {
        guard columns > 0, let s = series[id] else { return [] }
        let now = Date().timeIntervalSinceReferenceDate
        let t0 = now - window.rawValue
        let cells = self.cells(s, window: window, now: now)
        guard !cells.isEmpty else { return [] }
        var out: [Cell?] = Array(repeating: nil, count: columns)
        for c in cells {
            let i = min(max(Int((c.t - t0) / window.rawValue * Double(columns)), 0), columns - 1)
            if var o = out[i] { o.merge(c); out[i] = o } else { out[i] = c }
        }
        return out.compactMap { $0?.bucket }
    }

    /// Last 5 minutes, ≤ points values (sparklines). Cached per `sparklineRevision`: between its steps every caller
    /// gets the same array, so a sparkline is redrawn about every 5 s, not on every tick.
    func sparkline(_ id: SeriesID, points: Int) -> [Float] {
        guard points > 0, let s = series[id] else { return [] }
        if sparklineCacheRevision != sparklineRevision {
            sparklineCache.removeAll(keepingCapacity: true)
            sparklineCacheRevision = sparklineRevision
        }
        let key = SparklineKey(id: id, points: points)
        if let hit = sparklineCache[key] { return hit }
        let t0 = Date().timeIntervalSinceReferenceDate - Tier.sparklineWindow
        let values = Self.downsample(s.raw.elements(from: s.raw.lowerBound(t0) { $0.time.timeIntervalSinceReferenceDate }),
                                     maxPoints: points).map(\.value)
        sparklineCache[key] = values
        return values
    }

    func stats(_ id: SeriesID, window: HistoryWindow) -> SeriesStats? {
        guard let s = series[id] else { return nil }
        let cells = self.cells(s, window: window, now: Date().timeIntervalSinceReferenceDate)
        guard var total = cells.first else { return nil }
        for c in cells.dropFirst() { total.merge(c) }
        return SeriesStats(min: total.min, avg: Float(total.sum / Double(total.n)), max: total.max, count: total.n)
    }

    /// P1: CSV or JSON export of a time range (raw samples for ≤ 15 min, 10 s bucket averages before that).
    /// CSV: `timestamp,<series…>` with ISO 8601 local-offset times and "." decimals; one row per distinct time.
    func export(_ ids: [SeriesID], window: HistoryWindow, json: Bool) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        let columns = ids.map { id in (key: id.exportKey, samples: series[id].map { merged($0, window: window) } ?? []) }
        if json {
            let file = HistoryExport(app: "Thermik", format: 1, generated: iso.string(from: Date()), windowSeconds: window.rawValue,
                                     series: columns.map { c in
                                         HistoryExport.Series(id: c.key, samples: c.samples.map {
                                             HistoryExport.Point(t: iso.string(from: $0.time), v: (Double($0.value) * 100).rounded() / 100)
                                         })
                                     })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(file)) ?? Data()
        }
        var rows: [Date: [String?]] = [:]
        for (i, c) in columns.enumerated() {
            for s in c.samples {
                rows[s.time, default: Array(repeating: nil, count: columns.count)][i] = Self.decimal(s.value)
            }
        }
        var csv = (["timestamp"] + columns.map(\.key)).joined(separator: ",") + "\n"
        for t in rows.keys.sorted() {
            csv += ([iso.string(from: t)] + rows[t]!.map { $0 ?? "" }).joined(separator: ",") + "\n"
        }
        return Data(csv.utf8)
    }

    func clear() {
        series.removeAll()
        sparklineCache.removeAll()
        revision &+= 1
        sparklineRevision &+= 1
        longWindowRevision &+= 1
    }

    // MARK: Helpers for charts (Units 7/8) and diagnostics

    /// Splits a time-ordered series where Δt > `gapFactor` × the median spacing (SPEC §2.8: start a new `series:`
    /// value per segment so Swift Charts does not draw a line across a gap).
    nonisolated static func segments(_ samples: [Sample], gapFactor: Double = 3) -> [[Sample]] {
        guard samples.count > 2 else { return samples.isEmpty ? [] : [samples] }
        var gaps = [TimeInterval](); gaps.reserveCapacity(samples.count - 1)
        for i in 1..<samples.count { gaps.append(samples[i].time.timeIntervalSince(samples[i - 1].time)) }
        let median = gaps.sorted()[gaps.count / 2]
        let limit = Swift.max(median, 0.001) * gapFactor
        var out: [[Sample]] = [[samples[0]]]
        for i in 1..<samples.count {
            if gaps[i - 1] > limit { out.append([]) }
            out[out.count - 1].append(samples[i])
        }
        return out
    }

    /// One line per tier for the log / DEBUG "Dump History Stats".
    func debugSummary() -> String {
        var raw = 0, buckets = 0
        for s in series.values { raw += s.raw.count; buckets += s.buckets.count }
        let bytes = raw * MemoryLayout<Sample>.stride + buckets * MemoryLayout<StoredBucket>.stride
        let cpu = SeriesID.aggregate(.cpuAverage)
        return "series=\(series.count) raw=\(raw) buckets=\(buckets) ≈\(String(format: "%.1f", Double(bytes) / 1_048_576)) MB; "
            + "cpuAverage: samples(5 min)=\(samples(cpu, window: .m5, maxPoints: .max).count) "
            + "samples(1 h)=\(samples(cpu, window: .h1, maxPoints: .max).count) sparkline(60)=\(sparkline(cpu, points: 60).count) "
            + "stats(15 min)=\(stats(cpu, window: .m15).map { String(format: "%.1f/%.1f/%.1f", $0.min, $0.avg, $0.max) + " n=\($0.count)" } ?? "—")"
    }

    // MARK: Private

    /// Raw samples for ≤ 15 min windows; older 10 s bucket averages (bucket midpoints) before the raw span.
    private func merged(_ s: SeriesHistory, window: HistoryWindow) -> [Sample] {
        let now = Date().timeIntervalSinceReferenceDate
        let t0 = now - window.rawValue
        let raw = s.raw.elements(from: s.raw.lowerBound(t0) { $0.time.timeIntervalSinceReferenceDate })
        guard window.rawValue > Tier.rawRetention else { return raw }
        let rawStart = raw.first?.time.timeIntervalSinceReferenceDate ?? .infinity
        var out = [Sample]()
        let first = s.buckets.lowerBound(t0) { $0.mid }
        out.reserveCapacity(s.buckets.count - first + raw.count)
        for i in first..<s.buckets.count {
            let b = s.buckets[i]
            guard b.mid < rawStart else { break }
            out.append(Sample(time: Date(timeIntervalSinceReferenceDate: b.mid), value: b.avg))
        }
        return out + raw
    }

    /// Weighted cells (buckets carry their sample count) for envelopes and statistics.
    private func cells(_ s: SeriesHistory, window: HistoryWindow, now: TimeInterval) -> [Cell] {
        let t0 = now - window.rawValue
        let raw = s.raw.elements(from: s.raw.lowerBound(t0) { $0.time.timeIntervalSinceReferenceDate })
        var out = [Cell]()
        if window.rawValue > Tier.rawRetention {
            let rawStart = raw.first?.time.timeIntervalSinceReferenceDate ?? .infinity
            for i in s.buckets.lowerBound(t0, key: { $0.mid })..<s.buckets.count {
                let b = s.buckets[i]
                guard b.mid < rawStart else { break }
                out.append(Cell(t: b.mid, min: b.min, max: b.max, sum: Double(b.avg) * Double(b.n), n: Int(b.n)))
            }
        }
        for r in raw {
            out.append(Cell(t: r.time.timeIntervalSinceReferenceDate, min: r.value, max: r.value, sum: Double(r.value), n: 1))
        }
        return out
    }

    private static func downsample(_ data: [Sample], maxPoints: Int) -> [Sample] {
        guard data.count > maxPoints else { return data }
        switch maxPoints {
        case ...0: return []
        case 1: return [data[data.count - 1]]
        case 2: return [data[0], data[data.count - 1]]
        default: return Downsample.lttb(data, threshold: maxPoints)     // keeps thermal peaks visible
        }
    }

    private static func decimal(_ v: Float) -> String {
        let s = String(format: "%.2f", Double(v))       // C locale: always "." (CSV rule, SPEC §2.12)
        return s.hasSuffix(".00") ? String(s.dropLast(3)) : s
    }
}

// MARK: - Storage

/// Fixed-capacity ring that allocates as it fills (the frozen `RingBuffer` preallocates its whole capacity).
/// Elements are appended in time order; logical index 0 is the oldest.
private struct HistoryRing<Element> {
    private var storage = ContiguousArray<Element>()
    private var head = 0
    private(set) var capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { storage.count }
    subscript(i: Int) -> Element { storage[(head + i) % storage.count] }
    var last: Element? { storage.isEmpty ? nil : self[storage.count - 1] }

    mutating func append(_ e: Element) {
        if storage.count < capacity { storage.append(e) } else { storage[head] = e; head = (head + 1) % capacity }
    }

    /// Raises the capacity (a sensor got pinned: 6 h → 24 h). Never shrinks, so nothing recorded is lost.
    mutating func grow(to newCapacity: Int) {
        guard newCapacity > capacity else { return }
        if head != 0 { storage = ContiguousArray(storage[head...]) + storage[..<head]; head = 0 }
        capacity = newCapacity
    }

    mutating func removeAll() { storage.removeAll(); head = 0 }

    /// First logical index whose time key is ≥ t (binary search).
    func lowerBound(_ t: Double, key: (Element) -> Double) -> Int {
        var lo = 0, hi = storage.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if key(self[mid]) < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func elements(from i: Int) -> [Element] {
        guard i < storage.count else { return [] }
        var out = [Element](); out.reserveCapacity(storage.count - i)
        for j in i..<storage.count { out.append(self[j]) }
        return out
    }
}

/// 10 s bucket as stored (24 B, same stride as `Bucket`): start time + min/avg/max + sample count.
private struct StoredBucket {
    var start: Double            // timeIntervalSinceReferenceDate, a multiple of 10 s
    var min: Float
    var avg: Float
    var max: Float
    var n: UInt16
    var mid: Double { start + HistoryStore.Tier.bucketSeconds / 2 }
}

private struct OpenBucket {
    let start: Double
    var min: Float, max: Float
    var sum: Double
    var n: Int
    init(start: Double, _ v: Float) { self.start = start; min = v; max = v; sum = Double(v); n = 1 }
    mutating func add(_ v: Float) { min = Swift.min(min, v); max = Swift.max(max, v); sum += Double(v); n += 1 }
    var stored: StoredBucket {
        StoredBucket(start: start, min: min, avg: Float(sum / Double(n)), max: max, n: UInt16(clamping: n))
    }
}

private struct SeriesHistory {
    var raw = HistoryRing<Sample>(capacity: HistoryStore.Tier.rawCapacity)
    var buckets: HistoryRing<StoredBucket>
    var open: OpenBucket?

    init(bucketCapacity: Int) { buckets = HistoryRing(capacity: bucketCapacity) }

    mutating func append(_ v: Float, at date: Date, bucketCapacity: Int) {
        let t = date.timeIntervalSinceReferenceDate
        if let last = raw.last?.time.timeIntervalSinceReferenceDate, t <= last {
            // The wall clock went back. A few seconds (NTP): drop the sample. More: start this series over, otherwise
            // recording would stall until the clock caught up again.
            guard last - t > 5 else { return }
            raw.removeAll(); buckets.removeAll(); open = nil
        }
        if bucketCapacity > buckets.capacity { buckets.grow(to: bucketCapacity) }
        raw.append(Sample(time: date, value: v))
        let start = (t / HistoryStore.Tier.bucketSeconds).rounded(.down) * HistoryStore.Tier.bucketSeconds
        if var o = open, o.start == start {
            o.add(v); open = o
        } else {
            if let o = open { buckets.append(o.stored) }
            open = OpenBucket(start: start, v)
        }
    }
}

/// Weighted min/avg/max cell (a raw sample or a stored bucket).
private struct Cell {
    var t: Double
    var min: Float, max: Float
    var sum: Double
    var n: Int
    mutating func merge(_ o: Cell) { min = Swift.min(min, o.min); max = Swift.max(max, o.max); sum += o.sum; n += o.n }
    var bucket: Bucket {
        Bucket(time: Date(timeIntervalSinceReferenceDate: t), min: min, avg: Float(sum / Double(Swift.max(n, 1))), max: max)
    }
}

private struct HistoryExport: Encodable {
    struct Point: Encodable { let t: String; let v: Double }
    struct Series: Encodable { let id: String; let samples: [Point] }
    let app: String
    let format: Int
    let generated: String
    let windowSeconds: Double
    let series: [Series]
}

extension SeriesID {
    /// Stable machine key for exports and logs ("smc:Tp01", "aggregate:cpuAverage", "fan0_rpm", "power:systemTotal").
    var exportKey: String {
        switch self {
        case .sensor(let id): id.description
        case .aggregate(let k): "aggregate:\(k.rawValue)"
        case .fanRPM(let i): "fan\(i)_rpm"
        case .fanTarget(let i): "fan\(i)_target"
        case .power(let c): "power:\(c.rawValue)"
        case .cpuUsage: "cpu_usage"
        case .gpuUsage: "gpu_usage"
        case .pressure: "thermal_pressure"
        }
    }
}
