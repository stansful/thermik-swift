// EventLogStore.swift — Thermik (MIT). Implemented by Unit 0; OWNER afterwards: Unit 6 (API frozen; additions marked).
// In-memory event log (Logs page) + CSV event-column feed. Any unit may call record().
import Foundation
import Observation
import ThermikCore

@MainActor @Observable final class EventLogStore {
    private(set) var events: [AppEvent] = []
    let capacity = 2000
    /// ADDED (Unit 6): CSV tokens kept for CSVLoggingService between two drains (it drains every tick; the cap only
    /// matters if nothing drains, e.g. before the first tick).
    let csvTokenCapacity = 256
    @ObservationIgnored private var pendingCSV: [String] = []

    func record(_ payload: AppEventPayload, date: Date = Date()) {
        events.append(AppEvent(date: date, payload: payload))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        pendingCSV.append(payload.csvToken)
        if pendingCSV.count > csvTokenCapacity { pendingCSV.removeFirst(pendingCSV.count - csvTokenCapacity) }
    }

    /// Tokens recorded since the previous call (consumed by CSVLoggingService).
    func drainCSVTokens() -> [String] { defer { pendingCSV.removeAll() }; return pendingCSV }

    func clear() { events.removeAll(); pendingCSV.removeAll() }

    func events(since date: Date) -> [AppEvent] { events.filter { $0.date >= date } }
}
