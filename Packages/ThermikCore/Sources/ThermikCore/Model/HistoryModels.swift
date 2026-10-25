// HistoryModels.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). In-memory history types.
// RingBuffer / Downsample moved here from the design kit (research/design/kit/ThermikCharts.swift).
import Foundation

public struct Sample: Sendable, Hashable { public var time: Date; public var value: Float
    public init(time: Date, value: Float) { self.time = time; self.value = value } }

public struct Bucket: Sendable, Hashable { public var time: Date; public var min: Float; public var avg: Float; public var max: Float
    public init(time: Date, min: Float, avg: Float, max: Float) { self.time = time; self.min = min; self.avg = avg; self.max = max } }

public enum PowerChannel: String, Codable, Sendable, CaseIterable { case systemTotal, dcIn, battery, soc, cpu, gpu }

/// One history series.
public enum SeriesID: Hashable, Codable, Sendable {
    case sensor(SensorID)
    case aggregate(AggregateKind)
    case fanRPM(Int)
    case fanTarget(Int)
    case power(PowerChannel)
    case cpuUsage, gpuUsage
    case pressure                              // ThermalPressure.rawValue as Float
}

public enum HistoryWindow: TimeInterval, CaseIterable, Identifiable, Codable, Sendable {
    case m5 = 300, m15 = 900, h1 = 3600, h6 = 21600, h24 = 86400
    public var id: TimeInterval { rawValue }
}

public struct SeriesStats: Sendable, Equatable {
    public var min: Float, avg: Float, max: Float
    public var count: Int
    public init(min: Float, avg: Float, max: Float, count: Int) { self.min = min; self.avg = avg; self.max = max; self.count = count }
}

/// Fixed-capacity ring buffer. 24 h @ 1 Hz = 86 400 samples × 8 B ≈ 675 KiB per series.
public struct RingBuffer<Element>: RandomAccessCollection {
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0
    public let capacity: Int
    public init(capacity: Int) { self.capacity = Swift.max(1, capacity); storage = Array(repeating: nil, count: Swift.max(1, capacity)) }
    public mutating func append(_ e: Element) {
        let idx = (head + count) % capacity
        storage[idx] = e
        if count < capacity { count += 1 } else { head = (head + 1) % capacity }
    }
    public mutating func removeAll() { storage = Array(repeating: nil, count: capacity); head = 0; count = 0 }
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public subscript(i: Int) -> Element { storage[(head + i) % capacity]! }
}
extension RingBuffer: Sendable where Element: Sendable {}

public enum Downsample {
    /// Largest-Triangle-Three-Buckets — keeps visual peaks (thermal spikes must not vanish).
    public static func lttb(_ data: [Sample], threshold: Int) -> [Sample] {
        guard threshold > 2, data.count > threshold else { return data }
        var out: [Sample] = [data[0]]
        out.reserveCapacity(threshold)
        let every = Double(data.count - 2) / Double(threshold - 2)
        var a = 0
        for i in 0..<(threshold - 2) {
            let avgStart = Int(Double(i + 1) * every) + 1
            let avgEnd = min(Int(Double(i + 2) * every) + 1, data.count)
            var avgX = 0.0, avgY = 0.0
            for j in avgStart..<avgEnd { avgX += data[j].time.timeIntervalSinceReferenceDate; avgY += Double(data[j].value) }
            let n = Double(max(avgEnd - avgStart, 1)); avgX /= n; avgY /= n
            let rangeStart = Int(Double(i) * every) + 1
            let rangeEnd = Int(Double(i + 1) * every) + 1
            let ax = data[a].time.timeIntervalSinceReferenceDate, ay = Double(data[a].value)
            var maxArea = -1.0, next = rangeStart
            for j in rangeStart..<rangeEnd {
                let bx = data[j].time.timeIntervalSinceReferenceDate, by = Double(data[j].value)
                let area = abs((ax - avgX) * (by - ay) - (ax - bx) * (avgY - ay))
                if area > maxArea { maxArea = area; next = j }
            }
            out.append(data[next]); a = next
        }
        out.append(data[data.count - 1])
        return out
    }

    /// Min/max envelope per pixel column (6 h / 24 h views: avg line + min–max band).
    public static func envelope(_ data: [Sample], columns: Int) -> [Bucket] {
        guard let first = data.first?.time, let last = data.last?.time, columns > 0 else { return [] }
        let span = max(last.timeIntervalSince(first), 1)
        var buckets = [Bucket?](repeating: nil, count: columns)
        var sums = [Double](repeating: 0, count: columns), counts = [Int](repeating: 0, count: columns)
        for s in data {
            let c = min(Int(s.time.timeIntervalSince(first) / span * Double(columns)), columns - 1)
            if var b = buckets[c] { b.min = Swift.min(b.min, s.value); b.max = Swift.max(b.max, s.value); buckets[c] = b }
            else { buckets[c] = Bucket(time: s.time, min: s.value, avg: s.value, max: s.value) }
            sums[c] += Double(s.value); counts[c] += 1
        }
        return buckets.enumerated().compactMap { i, b in
            guard var b else { return nil }; b.avg = Float(sums[i] / Double(counts[i])); return b
        }
    }
}
