// SensorAggregator.swift — Thermik (MIT). OWNER: Unit 1. STUB from Unit 0; API FROZEN.
// Pure: computes AggregateValues and per-DisplayGroup stats from one frame of VALID raw values (§2.5.4).
import Foundation

public struct SensorAggregator: Sendable {
    public let inventory: SensorInventory
    public init(inventory: SensorInventory) { self.inventory = inventory }

    /// Headline aggregates from valid (sanitized, unsmoothed) values. Missing inputs → key absent.
    public func aggregates(_ values: [SensorID: Double], visible: Set<SensorID>) -> AggregateValues { .empty }

    /// Mean / max / hottest per display group over `visible` sensors that have a valid value.
    public func groupStats(_ values: [SensorID: Double], visible: Set<SensorID>) -> [DisplayGroup: GroupStat] { [:] }
}
