// AlertRuleEditor.swift — Thermik (MIT). Unit 8. Add / Edit sheet for one AlertRule (SPEC §4.6 W9, §2.10): subject
// (any sensor, aggregates, groups, a specific sensor, fan stalled, fan mode changed, thermal pressure, abnormal
// shutdown, battery service), threshold, duration, hysteresis, cooldown, sound (P1) and "Fans to Max" (P1).
// Thresholds are stored in °C and shown in the user's unit. Email / webhook channels are P2 and hidden in v1.
import SwiftUI
import ThermikCore

struct AlertRuleEditor: View {
    @State var rule: AlertRule
    var isNew: Bool
    @Environment(AlertStore.self) private var alerts
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var choosingSensor = false

    static let aggregates: [AggregateKind] = [.cpuAverage, .cpuHottest, .gpuAverage, .gpuHottest, .socHottest, .socDie,
                                              .highestAll, .memory, .ssd, .battery]
    static let durations: [TimeInterval] = [0, 5, 10, 30, 60, 120, 300, 600]
    static let cooldowns: [TimeInterval] = [0, 60, 300, 600, 1800, 3600, 21_600, 86_400]

    var body: some View {
        let unit = settings.effectiveUnit
        VStack(spacing: 0) {
            Form {
                Section {
                    subjectPicker
                    Toggle(isOn: $rule.enabled) { Text("Enabled") }
                }
                if rule.subject.isTemperature {
                    Section {
                        LabeledContent {
                            HStack {
                                ThermikSlider(value: Binding(get: { rule.thresholdC ?? 90 }, set: { rule.thresholdC = $0.rounded() }), in: 40...110, step: 1)
                                    .frame(minWidth: 180)
                                Stepper(value: Binding(get: { rule.thresholdC ?? 90 }, set: { rule.thresholdC = min(max($0, 40), 110) }), in: 40...110) {
                                    Text(verbatim: ThermikFormat.temp(rule.thresholdC ?? 90, unit: unit)).font(ThermikFont.valueSmall)
                                        .frame(minWidth: 44, alignment: .trailing)
                                }
                            }
                        } label: { Text("Above") }
                        LabeledContent {
                            Stepper(value: $rule.hysteresisC, in: 1...20, step: 1) {
                                Text(verbatim: WindowFormat.tempDelta(rule.hysteresisC, unit)).font(ThermikFont.valueSmall)
                            }
                        } label: { Text("Hysteresis") }
                    } footer: {
                        Text("The alert re-arms only after the temperature falls below the threshold minus the hysteresis.")
                            .font(ThermikFont.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker(selection: $rule.forSeconds) {
                        ForEach(Self.durations, id: \.self) { d in
                            if d == 0 { Text("Immediately").tag(d) } else { Text(verbatim: WindowFormat.duration(d)).tag(d) }
                        }
                    } label: { Text("For at least") }
                    Picker(selection: $rule.cooldownSeconds) {
                        ForEach(Self.cooldowns, id: \.self) { d in
                            if d == 0 { Text("No limit").tag(d) } else { Text(verbatim: WindowFormat.duration(d)).tag(d) }
                        }
                    } label: { Text("Repeat at most every") }
                }
                Section {
                    Picker(selection: Binding(get: { rule.soundName ?? "" }, set: { rule.soundName = $0.isEmpty ? nil : $0 })) {
                        Text("Default sound").tag("")
                        ForEach(AlertSoundCatalog.names, id: \.self) { Text(verbatim: $0).tag($0) }
                    } label: { Text("Sound") }
                    Toggle(isOn: Binding(get: { rule.action == .setFansMax }, set: { rule.action = $0 ? .setFansMax : nil })) {
                        Text("Set the fans to Max when this alert is raised")
                    }
                }
            }
            .formStyle(.grouped)
            .toggleStyle(.thermikFormSwitch)
            Divider()
            HStack {
                if !isNew {
                    Button(role: .destructive) { alerts.remove(rule.id); dismiss() } label: { Text("Delete rule") }
                }
                Spacer()
                Button(role: .cancel) { dismiss() } label: { Text("Cancel") }
                    .keyboardShortcut(.cancelAction)
                Button { save() } label: { isNew ? Text("Add Rule") : Text("Save") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 520, height: 560)
        .sheet(isPresented: $choosingSensor) {
            SensorChooserSheet(title: String(localized: "Alert sensor"),
                               current: { if case .sensor(let id) = rule.subject { return id }; return nil }()) { id in
                rule.subject = .sensor(id)
                if rule.thresholdC == nil { rule.thresholdC = 90 }
            }
        }
    }

    private enum SubjectChoice: Hashable { case subject(AlertRule.Subject), chooseSensor }

    private var subjectPicker: some View {
        Picker(selection: Binding<SubjectChoice>(
            get: { .subject(rule.subject) },
            set: { choice in
                switch choice {
                case .subject(let s):
                    rule.subject = s
                    if s.isTemperature, rule.thresholdC == nil { rule.thresholdC = 90 }
                case .chooseSensor:
                    choosingSensor = true
                }
            })) {
            Text("Any sensor").tag(SubjectChoice.subject(.anySensor))
            Section {
                ForEach(Self.aggregates, id: \.self) { k in Text(verbatim: k.title).tag(SubjectChoice.subject(.aggregate(k))) }
            }
            Section {
                ForEach(DisplayGroup.allCases, id: \.self) { g in
                    Text(verbatim: String(localized: "Hottest sensor in \(g.title)")).tag(SubjectChoice.subject(.group(g)))
                }
            }
            Section {
                if case .sensor(let id) = rule.subject {
                    Text(verbatim: sensors.sensor(id)?.displayName ?? id.description).tag(SubjectChoice.subject(rule.subject))
                }
                Text("Specific sensor…").tag(SubjectChoice.chooseSensor)
            }
            Section {
                Text("A fan stalled").tag(SubjectChoice.subject(.fanStalled))
                Text("Fan mode changed").tag(SubjectChoice.subject(.fanModeChanged))
                ForEach([ThermalPressure.moderate, .heavy, .trapping], id: \.self) { p in
                    Text(verbatim: String(localized: "Thermal pressure at least \(p.title)")).tag(SubjectChoice.subject(.thermalPressure(p)))
                }
                Text("Abnormal last shutdown").tag(SubjectChoice.subject(.abnormalShutdown))
                Text("Battery needs service").tag(SubjectChoice.subject(.batteryService))
            }
        } label: { Text("When") }
    }

    private func save() {
        if !rule.subject.isTemperature { rule.thresholdC = nil }
        if isNew { alerts.add(rule) } else { alerts.update(rule) }
        dismiss()
    }
}

/// System alert sounds (names usable with UNNotificationSound(named:)), read once from /System/Library/Sounds.
enum AlertSoundCatalog {
    @MainActor static let names: [String] = {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["aiff", "aif", "caf", "wav"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }()
}
