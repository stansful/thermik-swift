// DiagnosticsStore.swift — Thermik (MIT). STUB by Unit 0; OWNER: Unit 6. Surface FROZEN.
import Foundation
import Observation
import ThermikCore

@MainActor @Observable final class DiagnosticsStore: TickConsumer {
    @ObservationIgnored let sensors: SensorStore
    @ObservationIgnored let fans: FanStore
    @ObservationIgnored let system: SystemStore
    @ObservationIgnored let helper: HelperManager
    @ObservationIgnored let sampler: any SystemSampling
    @ObservationIgnored let events: EventLogStore

    private(set) var items: [DiagnosticItem] = []
    private(set) var powerLog: [PowerLogEvent] = []
    private(set) var isLoadingPowerLog = false
    var overall: DiagnosticStatus { items.map(\.status).max() ?? .unknown }
    /// Fans the engine considers stalled (feeds the fanStalled alert).
    private(set) var stalledFans: [Int] = []

    init(sensors: SensorStore, fans: FanStore, system: SystemStore, helper: HelperManager, sampler: any SystemSampling,
         events: EventLogStore) {
        self.sensors = sensors; self.fans = fans; self.system = system; self.helper = helper; self.sampler = sampler
        self.events = events
    }

    func consume(_ tick: Tick) {}
    /// Re-evaluate everything now (cheap; slow data comes from SystemStore).
    func refresh() {}
    /// `pmset -g log` on demand (1.4–3.4 s, off-main).
    func loadPowerLog() async {}
    /// Markdown report for GitHub issues (serials redacted) — "Copy report".
    func makeReport() -> String { "" }
}
