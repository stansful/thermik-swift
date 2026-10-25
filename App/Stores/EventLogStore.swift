// EventLogStore.swift — Thermik (MIT). Implemented by Unit 0; OWNER afterwards: Unit 6 (API frozen).
// In-memory event log (Logs page) + CSV event-column feed. Any unit may call record().
import Foundation
import Observation
import ThermikCore

@MainActor @Observable final class EventLogStore {
    private(set) var events: [AppEvent] = []
    let capacity = 2000
    @ObservationIgnored private var pendingCSV: [String] = []

    func record(_ payload: AppEventPayload, date: Date = Date()) {
        events.append(AppEvent(date: date, payload: payload))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        pendingCSV.append(payload.csvToken)
    }

    /// Tokens recorded since the previous call (consumed by CSVLoggingService).
    func drainCSVTokens() -> [String] { defer { pendingCSV.removeAll() }; return pendingCSV }

    func clear() { events.removeAll(); pendingCSV.removeAll() }

    func events(since date: Date) -> [AppEvent] { events.filter { $0.date >= date } }
}
