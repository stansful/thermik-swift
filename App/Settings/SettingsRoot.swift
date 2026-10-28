// SettingsRoot.swift — Thermik (MIT). Unit 0 stub; OWNER: Unit 8. Content of one Settings tab (SPEC §4.7); the
// tabs are the strip of SettingsPage, the Settings page of the main window. Every control writes its SettingsStore key immediately
// (keys: §2.11). This file: General, Menu Bar, Sensors, Fans. SettingsTabs.swift: Alerts, Logging, Appearance,
// Helper, Advanced, About.
import AppKit
import SwiftUI
import ThermikCore
import ThermikHelperShared

struct SettingsRoot: View {
    var tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings()
            case .menuBar: MenuBarSettings()
            case .sensors: SensorSettings()
            case .fans: FanSettings()
            case .alerts: SettingsAlertsTab()
            case .logging: Form { LoggingSettingsSection() }.formStyle(.grouped).toggleStyle(.thermikFormSwitch)
            case .appearance: SettingsAppearanceTab()
            case .helper: SettingsHelperTab()
            case .advanced: SettingsAdvancedTab()
            case .about: SettingsAboutTab()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(FanStore.self) private var fans
    @Environment(AppRouter.self) private var router
    @State private var confirmReset = false
    @State private var launchLanguage: LanguagePreference?

    var body: some View {
        @Bindable var s = settings
        let login = LaunchAtLogin.shared
        Form {
            Section {
                // The toggle writes the intent; LaunchAtLogin (Unit 5) observes it and registers SMAppService.mainApp.
                Toggle(isOn: $s.launchAtLogin) { Text("Launch at login") }
                if settings.launchAtLogin, login.requiresApproval {
                    HStack {
                        Text("Approve Thermik in System Settings › Login Items").font(ThermikFont.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { login.openSystemSettings() } label: { Text("Open Login Items") }
                    }
                }
                if let error = login.lastError {
                    Text(verbatim: error).font(ThermikFont.caption).foregroundStyle(Color(nsColor: .systemRed))
                }
                Picker(selection: $s.updateInterval) {
                    ForEach(SettingsStore.updateIntervals, id: \.self) { v in Text("\(Int(v)) s").tag(v) }
                } label: { Text("Update interval") }
                Text("While the popover or the main window is open, and while Thermik controls the fans, readings update every second.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker(selection: $s.temperatureUnit) {
                    ForEach(TemperatureUnitPreference.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { Text("Temperature unit") }
                Picker(selection: $s.language) {
                    ForEach(LanguagePreference.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { Text("Language") }
                if let launched = launchLanguage, launched != settings.language {
                    HStack {
                        Text("The new language is used after Thermik relaunches.").font(ThermikFont.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { AppRelauncher.relaunch() } label: { Text("Relaunch Now") }
                    }
                }
                Toggle(isOn: $s.showDockIconWhileWindowOpen) { Text("Show Dock icon while a window is open") }
            }
            Section {
                // Global hot keys (P1, Unit 5's HotKeys): recorded combos are stored in settings.hotKeys.
                ForEach([HotKeyAction.showMainWindow, .togglePopover], id: \.self) { action in
                    LabeledContent {
                        HotKeyRecorder(action: action)
                    } label: { Text(verbatim: action.title) }
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("These shortcuts work in every app. None is set by default.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
            Section {
                Button { router.showOnboarding() } label: { Text("Show Welcome Guide…") }
                Button(role: .destructive) { confirmReset = true } label: { Text("Reset to Defaults…") }
            } footer: {
                Text("Resetting returns the fans to Auto, restores every setting (alert rules, sensor names, menu bar, logging) and relaunches Thermik.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.thermikFormSwitch)
        .onAppear { if launchLanguage == nil { launchLanguage = settings.language } }
        .confirmationDialog(Text("Reset all settings to their defaults?"), isPresented: $confirmReset) {
            Button(role: .destructive) {
                fans.resetToSystem()                 // fans back to Auto BEFORE the config is wiped (SettingsStore contract)
                settings.resetToDefaults()
                AppRelauncher.relaunch()
            } label: { Text("Reset and Relaunch") }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: {
            Text("The fans return to Auto first. This cannot be undone.")
        }
    }
}

/// Relaunch after a language change or a reset. Uses the lifecycle owner's relaunch (Unit 5): a helper shell waits
/// until this process has exited (so the new instance does not hit the single-instance check), gives up after 30 s,
/// keeps demo mode, and opens the app bundle again.
@MainActor enum AppRelauncher {
    static func relaunch() { AppDelegate.relaunch() }
}

// MARK: - Menu bar

private struct MenuBarSettings: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(FanStore.self) private var fans
    @Environment(SensorStore.self) private var sensors
    @State private var choosing: Slot?

    private enum Slot: Identifiable, Hashable { case primary, secondary, item(UUID); var id: Self { self } }
    private enum MetricChoice: Hashable { case metric(MenuBarMetric), chooseSensor }

    static let temperatureAggregates: [AggregateKind] = [.cpuAverage, .cpuHottest, .gpuAverage, .gpuHottest, .socHottest,
                                                         .highestAll, .averageAll, .memory, .ssd, .battery]

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                LabelStyleGallery()
            } header: {
                Text("Style")
            }
            if settings.menuBar.style == .custom {
                customValues
                customLayout
            } else {
                Section {
                    HStack {
                        Text("Change the values, icons and layout of this style in your own variant.")
                            .font(ThermikFont.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            settings.menuBar.custom = settings.menuBar.style.editableComposition(settings.menuBar)
                            settings.menuBar.style = .custom
                        } label: { Text("Customise…") }
                    }
                }
            }
            Section {
                metricPicker(String(localized: "Primary value"), slot: .primary, value: settings.menuBar.primary, allowsFans: false)
                metricPicker(String(localized: "Secondary value"), slot: .secondary, value: settings.menuBar.secondary, allowsFans: true)
            } header: {
                Text("Values")
            } footer: {
                Text("The primary value is the temperature every style shows; the secondary one is the second value of the two-value styles. Your own variant chooses its values itself.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $s.menuBar.colored) { Text("Coloured temperature") }
                Toggle(isOn: $s.menuBar.alertColor) { Text("Colour while an alert is raised or the Mac is very hot") }
                Toggle(isOn: $s.menuBar.showOverrideBadge) { Text("Show ◆ while Thermik controls the fans") }
                Toggle(isOn: $s.menuBar.warnWhenHidden) { Text("Warn when the menu bar item is hidden") }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.thermikFormSwitch)
        .sheet(item: $choosing) { slot in
            SensorChooserSheet(title: String(localized: "Menu bar sensor"), current: nil) { id in
                assign(.temperature(.sensor(id)), to: slot)
            }
        }
    }

    // MARK: «Свой вариант»

    private var custom: MenuBarCustomLabel { settings.menuBar.custom ?? .standard }

    private func editCustom(_ change: (inout MenuBarCustomLabel) -> Void) {
        var c = custom
        change(&c)
        settings.menuBar.custom = c
    }

    /// Values 1…4: what each shows (any sensor included), its icon, caption and unit; reorder and remove.
    @ViewBuilder private var customValues: some View {
        let label = custom
        Section {
            HStack { Spacer(); LabelPreview(style: .custom); Spacer() }
                .padding(.vertical, 4)
            ForEach(Array(label.items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    metricPicker(String(localized: "Value \(index + 1)"), slot: .item(item.id), value: item.metric,
                                 allowsFans: true, allowsNone: false)
                    Picker(selection: itemBinding(item.id, \.icon)) {
                        ForEach(MenuBarIcon.allCases, id: \.self) { icon in
                            Label { Text(verbatim: icon.title) } icon: {
                                Image(systemName: MenuBarStyle.previewSymbol(icon, for: item.metric))
                            }
                            .tag(icon)
                        }
                    } label: { EmptyView() }
                    .labelsHidden()
                    .frame(width: 170)
                    .accessibilityLabel(Text("Icon"))
                    TextField(text: captionBinding(item.id), prompt: Text("Caption")) { EmptyView() }
                        .frame(width: 64)
                        .help(Text("Short text before the value, e.g. GPU (up to 4 characters)"))
                    if item.metric.isFanMetric || item.metric == .systemPower {
                        Toggle(isOn: itemBinding(item.id, \.showUnit)) { Text("Unit") }
                            .toggleStyle(.checkbox)
                    }
                    Button { move(item.id, by: -1) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderless).disabled(index == 0)
                        .accessibilityLabel(Text("Move up"))
                    Button { move(item.id, by: 1) } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(.borderless).disabled(index == label.items.count - 1)
                        .accessibilityLabel(Text("Move down"))
                    Button { editCustom { $0.items.removeAll { $0.id == item.id } } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).disabled(label.items.count == 1)
                        .accessibilityLabel(Text("Remove"))
                }
            }
            Button {
                editCustom { c in
                    guard c.items.count < MenuBarCustomLabel.maxItems else { return }
                    c.items.append(MenuBarLabelItem(metric: .temperature(.aggregate(.gpuAverage))))
                }
            } label: { Label { Text("Add value") } icon: { Image(systemName: "plus.circle") } }
            .disabled(label.items.count >= MenuBarCustomLabel.maxItems)
        } header: {
            Text(verbatim: MenuBarStyle.custom.title)
        } footer: {
            Text("Pick any sensor with “Specific sensor…”. Captions are short labels such as GPU or SSD.")
                .font(ThermikFont.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var customLayout: some View {
        Section {
            Picker(selection: layoutBinding(\.layout)) {
                ForEach(MenuBarCustomLabel.Layout.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: { Text("Layout") }
            .pickerStyle(.segmented)
            Picker(selection: layoutBinding(\.size)) {
                ForEach(MenuBarCustomLabel.TextSize.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: { Text("Text size") }
            .pickerStyle(.segmented)
            Picker(selection: layoutBinding(\.separator)) {
                ForEach(MenuBarCustomLabel.Separator.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: { Text("Between values") }
            .pickerStyle(.segmented)
            Toggle(isOn: layoutBinding(\.bold)) { Text("Bold digits") }
            Toggle(isOn: layoutBinding(\.badge)) { Text("Badge around the label") }
            Toggle(isOn: layoutBinding(\.tintIcons)) { Text("Icons in the value’s colour") }
                .disabled(!settings.menuBar.colored)
        } footer: {
            Text("In two rows, values 1 and 2 form the first column and 3 and 4 the second. Ring, level and mini graph are drawn in one row only.")
                .font(ThermikFont.caption).foregroundStyle(.secondary)
        }
    }

    private func itemBinding<V>(_ id: UUID, _ path: WritableKeyPath<MenuBarLabelItem, V>) -> Binding<V> {
        Binding(
            get: { (custom.items.first { $0.id == id } ?? MenuBarCustomLabel.standard.items[0])[keyPath: path] },
            set: { v in editCustom { c in if let i = c.items.firstIndex(where: { $0.id == id }) { c.items[i][keyPath: path] = v } } })
    }

    private func captionBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { custom.items.first { $0.id == id }?.caption ?? "" },
            set: { v in
                let short = String(v.trimmingCharacters(in: .whitespaces).prefix(MenuBarLabelItem.captionLimit))
                editCustom { c in if let i = c.items.firstIndex(where: { $0.id == id }) { c.items[i].caption = short } }
            })
    }

    private func layoutBinding<V>(_ path: WritableKeyPath<MenuBarCustomLabel, V>) -> Binding<V> {
        Binding(get: { custom[keyPath: path] }, set: { v in editCustom { $0[keyPath: path] = v } })
    }

    private func move(_ id: UUID, by delta: Int) {
        editCustom { c in
            guard let i = c.items.firstIndex(where: { $0.id == id }), c.items.indices.contains(i + delta) else { return }
            c.items.swapAt(i, i + delta)
        }
    }

    // MARK: Metric choice

    private func assign(_ m: MenuBarMetric, to slot: Slot) {
        switch slot {
        case .primary: settings.menuBar.primary = m
        case .secondary: settings.menuBar.secondary = m
        case .item(let id): editCustom { c in if let i = c.items.firstIndex(where: { $0.id == id }) { c.items[i].metric = m } }
        }
    }

    private func metricPicker(_ title: String, slot: Slot, value: MenuBarMetric, allowsFans: Bool,
                              allowsNone: Bool = true) -> some View {
        Picker(selection: Binding<MetricChoice>(
            get: { .metric(value) },
            set: { choice in
                switch choice {
                case .metric(let m): assign(m, to: slot)
                case .chooseSensor: choosing = slot
                }
            })) {
            if allowsFans && fans.hasFans {
                Section {
                    Text("Average fan speed").tag(MetricChoice.metric(.fanAverage))
                    Text("Fastest fan").tag(MetricChoice.metric(.fanMax))
                    ForEach(fans.fans) { f in Text(verbatim: f.localizedName).tag(MetricChoice.metric(.fan(f.id))) }
                }
            }
            Section {
                ForEach(Self.temperatureAggregates, id: \.self) { k in
                    Text(verbatim: k.title).tag(MetricChoice.metric(.temperature(.aggregate(k))))
                }
                if case .temperature(.sensor(let id)) = value {
                    Text(verbatim: sensors.sensor(id)?.displayName ?? id.description).tag(MetricChoice.metric(value))
                }
                Text("Specific sensor…").tag(MetricChoice.chooseSensor)
            }
            if allowsFans {
                Section {
                    Text("System power").tag(MetricChoice.metric(.systemPower))
                    if allowsNone { Text("Nothing").tag(MetricChoice.metric(.none)) }
                }
            }
        } label: { Text(verbatim: title) }
    }
}

// MARK: - Sensors

private struct SensorSettings: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(SensorStore.self) private var sensors
    @State private var confirmReset = false

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                Toggle(isOn: $s.showHiddenSensors) { Text("Show hidden sensors") }
                Toggle(isOn: $s.showRawKeys) { Text("Show raw SMC keys") }
                Toggle(isOn: $s.driveTemperatures) { Text("Read drive health (NVMe SMART) every minute") }
            } footer: {
                Text("Hidden sensors include raw, duplicate and firmware-summary keys. They are never used for alerts.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
            Section {
                Button { confirmReset = true } label: { Text("Reset Statistics") }
            } footer: {
                Text("Clears the minimum, average and maximum of every sensor since launch.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
            Section {
                let customized = customizedSensors
                if customized.isEmpty {
                    Text("No renamed, hidden or pinned sensors.").foregroundStyle(.secondary)
                } else {
                    ForEach(customized, id: \.id) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: entry.name)
                                Text(verbatim: entry.summary).font(ThermikFont.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { restore(entry.id) } label: { Text("Restore") }
                        }
                    }
                    Button { customized.forEach { restore($0.id) } } label: { Text("Restore All") }
                }
            } header: {
                Text("Customized sensors")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.thermikFormSwitch)
        .onChange(of: settings.showHiddenSensors) { _, _ in sensors.rebuildGroups() }
        .confirmationDialog(Text("Reset the statistics of every sensor?"), isPresented: $confirmReset) {
            Button(role: .destructive) { sensors.resetStatistics() } label: { Text("Reset Statistics") }
            Button(role: .cancel) {} label: { Text("Cancel") }
        }
    }

    private var customizedSensors: [(id: SensorID, name: String, summary: String)] {
        settings.sensorOverrides.compactMap { key, o -> (id: SensorID, name: String, summary: String)? in
            guard let id = SensorID(key) else { return nil }
            var parts: [String] = []
            if let n = o.name { parts.append(String(localized: "renamed to “\(n)”")) }
            if o.hidden == true { parts.append(String(localized: "hidden")) }
            if o.hidden == false, let s = sensors.sensor(id), !s.sensor.isVisibleByDefault { parts.append(String(localized: "shown")) }
            if o.pinned == true { parts.append(String(localized: "pinned")) }
            guard !parts.isEmpty else { return nil }
            let name = sensors.sensor(id).map { $0.sensor.name(preferRussian: settings.preferRussian) } ?? id.description
            return (id, name, parts.joined(separator: ", "))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Back to the catalog defaults for one sensor (name, visibility, pin) and drop its override entry.
    private func restore(_ id: SensorID) {
        if let s = sensors.sensor(id) {
            sensors.rename(id, to: nil)
            sensors.setHidden(id, !s.sensor.isVisibleByDefault)
            sensors.setPinned(id, false)
        }
        settings.sensorOverrides[id.description] = nil
    }
}

// MARK: - Fans

private struct FanSettings: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(FanStore.self) private var fans
    @State private var confirmCurves = false

    var body: some View {
        @Bindable var s = settings
        let unit = settings.effectiveUnit
        Form {
            Section {
                Toggle(isOn: $s.fans.restoreModeOnLaunch) { Text("Restore the last fan mode when Thermik starts") }
                Picker(selection: Binding(get: { settings.fans.maxAutoRevertMinutes ?? 0 },
                                          set: { settings.fans.maxAutoRevertMinutes = $0 == 0 ? nil : $0 })) {
                    Text("Never").tag(0)
                    ForEach(FanSettingsOptions.revertMinutes(including: settings.fans.maxAutoRevertMinutes), id: \.self) { m in
                        Text("\(m) min").tag(m)
                    }
                } label: { Text("Max returns to Auto after") }
            } footer: {
                Text("Off by default: every launch starts in Auto. Quitting Thermik always returns the fans to Auto.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
            Section {
                let top4 = ThermikFormat.temp(settings.fans.safety.criticalC, unit: unit)
                let hottest = ThermikFormat.temp(settings.fans.safety.rawCriticalC, unit: unit)
                let helperTop4 = ThermikFormat.temp(ThermikHelper.Safety.overrideTop4MeanC, unit: unit)
                let helperHottest = ThermikFormat.temp(ThermikHelper.Safety.overrideHottestC, unit: unit)
                LabeledContent {
                    Text(verbatim: "\(top4) · \(hottest)").font(ThermikFont.valueSmall)
                } label: { Text("Thermik safety override") }
                LabeledContent {
                    Text(verbatim: "\(helperTop4) · \(helperHottest)").font(ThermikFont.valueSmall)
                } label: { Text("Helper backstop") }
            } header: {
                Text("Safety")
            } footer: {
                Text("Forced fans go to maximum when the average of the 4 hottest die sensors or any single die sensor reaches these temperatures, until it is 6° cooler. These limits cannot be changed.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $s.fans.thermalGuard.enabled) { Text("Thermal guard") }
            } footer: {
                let floor = WindowFormat.percent(settings.fans.thermalGuard.moderateFloorPercent)
                Text(verbatim: String(localized: "When macOS reports moderate thermal pressure for 5 seconds the fans run at least \(floor); at heavy pressure they run at maximum. Released after 30 seconds of normal pressure.") + " " + String(localized: "In Auto, macOS alone controls the fans."))
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
            Section {
                Button { confirmCurves = true } label: { Text("Reset Curves to Balanced…") }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.thermikFormSwitch)
        .confirmationDialog(Text("Reset the fan curves?"), isPresented: $confirmCurves) {
            Button(role: .destructive) {
                fans.applyPreset(.balanced)
                settings.fans.curveBattery = nil
            } label: { Text("Reset Curves") }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: {
            Text("The adapter curve becomes the Balanced preset and the separate battery curve is removed.")
        }
    }
}
