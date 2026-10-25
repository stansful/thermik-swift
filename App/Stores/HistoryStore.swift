// HistoryStore.swift — Thermik (MIT). STUB by Unit 0; OWNER: Unit 5 (tiers: raw 15 min, 10 s buckets 24 h). API FROZEN.
import Foundation
import Observation
import ThermikCore

@MainActor @Observable final class HistoryStore: TickConsumer {
    /// Increments once per appended tick: charts read it to refresh (cheap observation hook).
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private weak var sensors: SensorStore?
    @ObservationIgnored private weak var fans: FanStore?
    @ObservationIgnored private weak var system: SystemStore?

    init(sensors: SensorStore) { self.sensors = sensors }
    /// Wired by AppEnvironment (fan rpm/target series; cpu/gpu usage and pressure series).
    func attach(fans: FanStore, system: SystemStore) { self.fans = fans; self.system = system }

    func consume(_ tick: Tick) { revision &+= 1 }

    /// Time-ordered samples within `window`, LTTB-downsampled to ≤ maxPoints.
    func samples(_ id: SeriesID, window: HistoryWindow, maxPoints: Int) -> [Sample] { [] }
    /// Min/avg/max buckets (6 h / 24 h views), ≤ columns.
    func buckets(_ id: SeriesID, window: HistoryWindow, columns: Int) -> [Bucket] { [] }
    /// Last 5 minutes, ≤ points values (sparklines).
    func sparkline(_ id: SeriesID, points: Int) -> [Float] { [] }
    func stats(_ id: SeriesID, window: HistoryWindow) -> SeriesStats? { nil }
    /// P1: CSV or JSON export of a time range.
    func export(_ ids: [SeriesID], window: HistoryWindow, json: Bool) -> Data { Data() }
    func clear() { revision &+= 1 }
}
