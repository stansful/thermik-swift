// CSVLoggingService.swift — Thermik (MIT). STUB by Unit 0; OWNER: Unit 6. Surface FROZEN.
import Foundation
import ThermikCore

@MainActor final class CSVLoggingService: TickConsumer {
    let settings: SettingsStore
    let sensors: SensorStore
    let fans: FanStore
    let system: SystemStore
    let events: EventLogStore
    init(settings: SettingsStore, sensors: SensorStore, fans: FanStore, system: SystemStore, events: EventLogStore) {
        self.settings = settings; self.sensors = sensors; self.fans = fans; self.system = system; self.events = events
    }
    func consume(_ tick: Tick) {}
    /// Re-read settings.log (enable/disable, folder, columns) — call after the Logging settings change.
    func reconfigure() {}
    func revealInFinder() {}
    func flushAndClose() async {}
}
