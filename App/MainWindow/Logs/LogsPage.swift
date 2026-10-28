// LogsPage.swift — Thermik (MIT). Unit 8. Logs page (SPEC §4.6 W8, L3): table of in-app events (time, type, details;
// newest first) with a type filter and search, plus the CSV logging options inline (LoggingSettingsSection).
import SwiftUI
import ThermikCore

struct LogsPage: View {
    @Bindable var model: MainWindowModel
    @Environment(EventLogStore.self) private var events
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings
    @State private var filter: EventFilter = .all
    @State private var confirmClear = false
    @State private var showsCSV = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker(selection: $filter) {
                    ForEach(EventFilter.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { Text("Show") }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                Spacer()
                Toggle(isOn: $showsCSV) { Text("CSV logging") }
                    .toggleStyle(.button)
                Button(role: .destructive) { confirmClear = true } label: { Text("Clear…") }
                    .disabled(events.events.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            let rows = self.rows
            if events.events.isEmpty {
                ContentUnavailableView {
                    Label { Text("No events yet") } icon: { Image(systemName: "list.bullet.rectangle") }
                } description: {
                    Text("Alerts, fan mode changes, sleep and wake, and helper events appear here.")
                }
            } else if rows.isEmpty {
                if model.eventSearch.isEmpty {
                    ContentUnavailableView {
                        Label { Text("No matching events") } icon: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    }
                } else {
                    ContentUnavailableView.search(text: model.eventSearch)
                }
            } else {
                Table(rows) {
                    TableColumn("Time") { e in Text(verbatim: WindowFormat.dateTime(e.date)).font(ThermikFont.mono) }
                        .width(min: 140, ideal: 170)
                    TableColumn("Type") { e in
                        Label { Text(verbatim: EventLogText.kind(e.payload)) } icon: { Image(systemName: EventLogText.symbol(e.payload)) }
                    }
                    .width(min: 90, ideal: 120)
                    TableColumn("Details") { e in
                        Text(verbatim: EventLogText.details(e.payload, sensorName: sensorName, unit: settings.effectiveUnit))
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .thermikPlainRows()
            }
            if showsCSV {
                Divider()
                Form { LoggingSettingsSection() }
                    .formStyle(.grouped)
                    .toggleStyle(.thermikFormSwitch)
                    .frame(height: 300)
            }
        }
        .searchable(text: $model.eventSearch, placement: .toolbar, prompt: Text("Search events"))
        .confirmationDialog(Text("Clear the event log?"), isPresented: $confirmClear) {
            Button(role: .destructive) { events.clear() } label: { Text("Clear") }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: {
            Text("CSV log files on disk are not affected.")
        }
    }

    private var rows: [AppEvent] {
        let q = model.eventSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return events.events.reversed().filter { e in
            guard filter.matches(e.payload) else { return false }
            guard !q.isEmpty else { return true }
            return EventLogText.kind(e.payload).lowercased().contains(q)
                || EventLogText.details(e.payload, sensorName: sensorName, unit: settings.effectiveUnit).lowercased().contains(q)
        }
    }

    private func sensorName(_ id: SensorID) -> String? { sensors.sensor(id)?.displayName }
}

enum EventFilter: CaseIterable, Hashable {
    case all, alerts, fanMode, power, helper
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .alerts: String(localized: "Alerts")
        case .fanMode: String(localized: "Fan mode")
        case .power: String(localized: "Power")
        case .helper: String(localized: "Helper")
        }
    }
    func matches(_ p: AppEventPayload) -> Bool {
        switch self {
        case .all: true
        case .alerts: if case .alertRaised = p { true } else if case .alertCleared = p { true } else { false }
        case .fanMode: if case .fanModeChanged = p { true } else if case .safetyOverride = p { true } else { false }
        case .power:
            switch p {
            case .systemWillSleep, .systemDidWake, .powerSourceChanged, .thermalPressureChanged: true
            default: false
            }
        case .helper: if case .helperReverted = p { true } else if case .helperStatus = p { true } else { false }
        }
    }
}

/// Localized event texts (Logs page; also usable for notifications history).
enum EventLogText {
    static func kind(_ p: AppEventPayload) -> String {
        switch p {
        case .alertRaised: String(localized: "Alert")
        case .alertCleared: String(localized: "Alert cleared")
        case .fanModeChanged: String(localized: "Fan mode")
        case .helperReverted, .helperStatus: String(localized: "Helper")
        case .safetyOverride: String(localized: "Safety")
        case .systemWillSleep: String(localized: "Sleep")
        case .systemDidWake: String(localized: "Wake")
        case .powerSourceChanged: String(localized: "Power")
        case .thermalPressureChanged: String(localized: "Thermal pressure")
        case .appLaunched: String(localized: "Launch")
        case .error: String(localized: "Error")
        }
    }

    static func symbol(_ p: AppEventPayload) -> String {
        switch p {
        case .alertRaised: "bell.badge"
        case .alertCleared: "bell"
        case .fanModeChanged: "fan"
        case .helperReverted, .helperStatus: "lock.shield"
        case .safetyOverride: "exclamationmark.octagon"
        case .systemWillSleep: "moon.zzz"
        case .systemDidWake: "sun.max"
        case .powerSourceChanged: "powerplug"
        case .thermalPressureChanged: "gauge.with.dots.needle.50percent"
        case .appLaunched: "play.fill"
        case .error: "exclamationmark.triangle"
        }
    }

    @MainActor static func details(_ p: AppEventPayload, sensorName: (SensorID) -> String?, unit: UnitTemperature) -> String {
        switch p {
        case .alertRaised(_, let subject, let value, let sensorID):
            var name = subject.title(sensorName: sensorName)
            if let id = sensorID, let s = sensorName(id) { name += " (\(s))" }
            if let value { return String(localized: "\(name) reached \(ThermikFormat.temp(value, unit: unit, decimals: 1))") }
            return name
        case .alertCleared:
            return String(localized: "Back to normal")
        case .fanModeChanged(let c):
            return String(localized: "\(c.from.title) → \(c.to.title) (\(c.reason.title))")
        case .helperReverted(let reason):
            let why = HelperRevertReason.title(reason)            // machine token → phrase ("leaseExpired" → …)
            return String(localized: "Fans returned to Auto: \(why)")
        case .helperStatus(let a):
            return a?.title ?? String(localized: "Helper ready")
        case .safetyOverride(let engaged, let t):
            if engaged {
                let temp = t.map { ThermikFormat.temp($0, unit: unit) } ?? "—"
                return String(localized: "Safety override: fans at maximum (\(temp))")
            }
            return String(localized: "Safety override released")
        case .systemWillSleep:
            return String(localized: "The Mac went to sleep; fans returned to Auto")
        case .systemDidWake:
            return String(localized: "The Mac woke up")
        case .powerSourceChanged(let k):
            return String(localized: "Power source: \(k.title)")
        case .thermalPressureChanged(let pr):
            return String(localized: "Thermal pressure: \(pr.title)")
        case .appLaunched(let v):
            return String(localized: "Thermik \(v) started")
        case .error(let e):
            return errorText(e)
        }
    }

    /// `.error` payloads are free text. FanStore records localized ones; the sampler and the CSV logger record a fixed
    /// English prefix plus `String(describing: error)`, which is mapped here (anything else is shown as recorded).
    static func errorText(_ e: String) -> String {
        if e.hasPrefix("sensors unavailable: ") {                        // SensorSamplerError.noSensorSource
            return String(localized: "Sensors unavailable: Thermik could not open the SMC.")
        }
        if e.hasPrefix("CSV log: ") {
            let detail = String(e.dropFirst("CSV log: ".count))
            return String(localized: "CSV log: \(detail)")
        }
        return e
    }
}
