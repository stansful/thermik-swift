// SensorChooser.swift — Thermik (MIT). Unit 8. "Specific sensor…" picker sheet used by the fan-curve driving sensor
// and the alert rule editor: searchable list of temperature sensors grouped by display group, with live values.
import SwiftUI
import ThermikCore

struct SensorChooserSheet: View {
    var title: String
    var current: SensorID?
    var onChoose: (SensorID) -> Void
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: SensorID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: title).font(.headline)
                Spacer()
                TextField(text: $query) { Text("Search sensors") }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            .padding(14)
            Divider()
            List(selection: $selection) {
                ForEach(groups, id: \.group) { entry in
                    Section {
                        ForEach(entry.rows) { s in
                            HStack {
                                Text(verbatim: s.displayName).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(verbatim: WindowFormat.temp(s.value, settings.effectiveUnit)).font(ThermikFont.valueSmall)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(s.id)
                        }
                    } header: {
                        Text(verbatim: entry.group.title)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 320)
            Divider()
            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { Text("Cancel") }
                    .keyboardShortcut(.cancelAction)
                Button {
                    if let selection { onChoose(selection) }
                    dismiss()
                } label: { Text("Choose") }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(14)
        }
        .frame(width: 460, height: 480)
        .onAppear { selection = current }
    }

    private var groups: [(group: DisplayGroup, rows: [LiveSensor])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shown = sensors.sensors.filter { s in
            (settings.showHiddenSensors || !s.isHidden)
                && (q.isEmpty || s.displayName.lowercased().contains(q) || s.sensor.id.key.lowercased().contains(q))
        }
        return DisplayGroup.allCases.compactMap { g in
            let rows = shown.filter { $0.sensor.displayGroup == g }
            return rows.isEmpty ? nil : (g, rows)
        }
    }
}
