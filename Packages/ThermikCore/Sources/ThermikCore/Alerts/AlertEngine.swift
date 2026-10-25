// AlertEngine.swift — Thermik (MIT). OWNER: Unit 6. STUB from Unit 0; API FROZEN.
// Pure, stateful: duration ("for N s"), hysteresis re-arm and cooldown per rule (and per sensor for anySensor/group).
import Foundation

public struct AlertEngine: Sendable {
    public init() {}
    public mutating func evaluate(rules: [AlertRule], inputs: AlertInputs) -> [AlertEvent] { [] }
    public mutating func reset() {}
}
