// DiagnosticsEngine.swift — Thermik (MIT). OWNER: Unit 6. STUB from Unit 0; API FROZEN.
import Foundation
import ThermikSMC

public struct DiagnosticsEngine: Sendable {
    public init() {}
    /// Feed every tick: tracks fan stall / target mismatch and stuck / out-of-range sensors over time.
    public mutating func observe(frame: SensorFrame, commands: [Int: FanCommand], profile: FanHardwareProfile) {}
    /// Fans currently considered stalled (for the fanStalled alert).
    public var stalledFans: [Int] { [] }
    public func items(context: DiagnosticsContext, now: Date) -> [DiagnosticItem] { [] }
    /// Markdown report for GitHub issues. NEVER includes serial numbers, UUIDs or accessory names.
    public func report(items: [DiagnosticItem], machine: MachineInfo?, inventory: SensorInventory?, appVersion: String) -> String { "" }
}
