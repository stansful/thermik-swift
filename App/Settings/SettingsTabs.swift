// SettingsTabs.swift — Thermik (MIT). Unit 8. Settings tabs Alerts, Appearance, Helper, Advanced and About (SPEC §4.7).
// Logging reuses LoggingSettingsSection (shared with the Logs page).
import AppKit
import SwiftUI
import ThermikCore

// MARK: - Alerts

struct SettingsAlertsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AlertStore.self) private var alerts
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                Toggle(isOn: $s.alertsEnabled) { Text("Show alert notifications") }
                Picker(selection: Binding(get: { settings.alertSoundName ?? "" }, set: { settings.alertSoundName = $0.isEmpty ? nil : $0 })) {
                    Text("Default sound").tag("")
                    ForEach(AlertSoundCatalog.names, id: \.self) { Text(verbatim: $0).tag($0) }
                } label: { Text("Default sound") }
                Button { router.showMain(.alerts) } label: { Text("Edit Alert Rules…") }
            }
            Section {
                LabeledContent {
                    Text(verbatim: authorizationTitle).foregroundStyle(.secondary)
                } label: { Text("Notification permission") }
                switch alerts.authorization {
                case .denied:
                    Button { SystemSettingsLink.open(SystemSettingsLink.notifications) } label: { Text("Open Notification Settings") }
                case .notDetermined, .unknown:
                    Button { Task { await alerts.requestAuthorization() } } label: { Text("Allow Alerts") }
                case .authorized, .provisional:
                    Button { Task { await alerts.sendTestNotification() } } label: { Text("Send test notification") }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.thermikFormSwitch)
    }

    private var authorizationTitle: String {
        switch alerts.authorization {
        case .authorized: String(localized: "Allowed")
        case .provisional: String(localized: "Delivered quietly")
        case .denied: String(localized: "Turned off in System Settings")
        case .notDetermined: String(localized: "Not asked yet")
        case .unknown: String(localized: "Unknown")
        }
    }
}

// MARK: - Appearance

struct SettingsAppearanceTab: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                Toggle(isOn: $s.animatedEffects) { Text("Animated effects") }
                Toggle(isOn: $s.colorBlindScale) { Text("Colour-blind-friendly scale") }
                Picker(selection: $s.popoverDensity) {
                    ForEach(PopoverDensity.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: { Text("Popover density") }
            } footer: {
                Text("Heat glow and aurora also stop with Reduce Motion and in Low Power Mode. Colours always come with a number and a symbol.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
            Section {
                ColorScaleEditor()
            } header: {
                Text("Colour scale")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Each level starts at the temperature under it.")
                    Text("Sensor, menu bar and chart colours follow these temperatures. Notification thresholds are set separately in Alerts.")
                }
                .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.thermikFormSwitch)
    }
}

/// Editable colour scale: per sensor class, the temperature at which each of the seven level colours is reached, which
/// is also where that level begins (ThermalScale.level: popover chip, badges, Overview, VoiceOver).
/// Values stay strictly increasing (each at least 1° above the previous one); the strip shows the resulting ramp.
private struct ColorScaleEditor: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.thermikRamp) private var ramp
    @State private var thermalClass: ThermalClass = .soc

    var body: some View {
        let unit = settings.effectiveUnit
        // Reading `colorScales` here makes the editor redraw when it changes (the scale itself is not observable).
        let stored = settings.colorScales[thermalClass.rawValue]
        let temps = ThermalScale.scale(for: thermalClass).temps
        // Nothing to reset when the scale in effect is the default one: also for a stored entry equal to the defaults
        // (someone who had tuned exactly today's defaults by hand) or an invalid one (ignored by ThermalScaleOverrides).
        let isCustom = stored != nil && temps != thermalClass.stops
        VStack(alignment: .leading, spacing: 14) {
            Picker(selection: $thermalClass) {
                ForEach(ThermalClass.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: { Text("Sensors") }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(alignment: .top, spacing: 6) {
                ForEach(ThermalLevel.allCases, id: \.self) { level in
                    VStack(spacing: 5) {
                        LevelBadge(level: level, compact: true)
                            .frame(height: 22)                 // glyphs differ in height; keep the rows level
                        Text(level.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        StopField(value: binding(level.rawValue, unit: unit))
                            .accessibilityLabel(Text(verbatim: level.localizedTitle))
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            ScaleStrip(temps: temps, ramp: ramp, unit: unit)

            HStack {
                Spacer()
                Button {
                    settings.colorScales[thermalClass.rawValue] = nil
                } label: { Text("Reset scale") }
                .disabled(!isCustom)
            }
        }
        .padding(.vertical, 4)
    }

    /// One stop in the display unit, clamped between its neighbours (and to -20…130 °C) when set.
    private func binding(_ i: Int, unit: UnitTemperature) -> Binding<Double> {
        Binding(
            get: { ThermikFormat.convert(ThermalScale.scale(for: thermalClass).temps[i], to: unit).rounded() },
            set: { shown in
                guard shown.isFinite else { return }
                var t = ThermalScale.scale(for: thermalClass).temps
                // °F steps are 5/9 °C: keep a tenth of a degree so each step still moves the stop.
                let celsius = unit == .fahrenheit ? ((shown - 32) * 5 / 9 * 10).rounded() / 10 : shown.rounded()
                let lo = i > 0 ? t[i - 1] + 1 : -20
                let hi = i < t.count - 1 ? t[i + 1] - 1 : 130
                t[i] = min(max(celsius, lo), hi)
                settings.colorScales[thermalClass.rawValue] = t == thermalClass.stops ? nil : t
            })
    }
}

/// Compact numeric stop: typed value (applied on Return / focus loss) plus a mini stepper.
private struct StopField: View {
    @Binding var value: Double
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            TextField(value: $value, format: .number.precision(.fractionLength(0)).grouping(.never)) { EmptyView() }
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(ThermikFont.caption.monospacedDigit())
                .frame(width: 30)
            Text(verbatim: "°").font(ThermikFont.caption)
            Stepper(value: $value, step: 1) { EmptyView() }
                .labelsHidden()
                .controlSize(.mini)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .padding(.leading, 2)
        }
    }
}

/// The ramp as it falls on real temperatures: colour stops placed proportionally between the first and last value.
private struct ScaleStrip: View {
    let temps: [Double]
    let ramp: ThermikRamp
    let unit: UnitTemperature

    var body: some View {
        let lo = temps.first ?? 0, span = max((temps.last ?? 1) - lo, 1)
        let stops = temps.enumerated().map { i, t in
            Gradient.Stop(color: ramp.vivid(ThermalScale.stopT[i]), location: (t - lo) / span)
        }
        VStack(spacing: 4) {
            Capsule()
                .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
                .frame(height: 8)
            HStack {
                Text(verbatim: ThermikFormat.temp(lo, unit: unit))
                Spacer()
                Text(verbatim: ThermikFormat.temp(temps.last ?? 0, unit: unit))
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Helper

struct SettingsHelperTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ThermikMetrics.gutter) {
                HelperControlCard()
                Text("Thermik's own builds without a Developer ID use the privileged helper tool: installing asks once for an administrator password. Builds signed with a Team ID register the helper in Login Items instead, where you approve it. Either way, ./scripts/lib/uninstall-helper.sh removes it completely.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }
}

// MARK: - Advanced

struct SettingsAdvancedTab: View {
    /// Read directly by the system sampler (Unit 2); not part of SettingsStore (SPEC §2.11).
    @AppStorage("advanced.experimentalCLPCPower") private var experimentalCLPC = false
    @State private var copied = false

    static let logCommand = "log stream --predicate 'subsystem BEGINSWITH \"app.thermik\"' --level debug"

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $experimentalCLPC) { Text("Experimental CPU power (CLPC)") }
            } footer: {
                Text("Uses undocumented performance-controller counters for CPU watts. Values may be wrong; takes effect after a relaunch.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    HStack {
                        Button { copyCommand() } label: { copied ? Text("Copied") : Text("Copy Command") }
                        Button { openConsole() } label: { Text("Open Console") }
                    }
                } label: { Text("Diagnostic log") }
                Text(verbatim: Self.logCommand).font(ThermikFont.mono).foregroundStyle(.secondary).textSelection(.enabled)
            } footer: {
                Text("Paste the command into Terminal to follow Thermik's log live. Logs never leave this Mac.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.thermikFormSwitch)
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.logCommand, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func openConsole() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
    }
}

// MARK: - About

struct SettingsAboutTab: View {
    static let acknowledgements: [(name: String, license: String)] = [
        ("Stats (exelban)", "MIT"), ("macmon", "MIT"), ("SMCKit", "MIT"), ("Battery Toolkit", "BSD-3-Clause"),
        ("agoodkind/macos-smc-fan", "MIT"), ("VirtualSMC", "BSD-3-Clause"),
    ]

    var body: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        ScrollView {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text(verbatim: "Thermik").font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(verbatim: String(localized: "Version \(version) (\(build))")).foregroundStyle(.secondary)
                Text("See the heat. Ride it calmly.").font(.system(size: 13, weight: .medium))
                VStack(alignment: .leading, spacing: 8) {
                    Label { Text("Free and open source under the MIT License.") } icon: { Image(systemName: "checkmark.seal") }
                    Label { Text("No telemetry: Thermik never connects to the network.") } icon: { Image(systemName: "lock.shield") }
                    Label { Text("Fans always return to Auto when Thermik quits.") } icon: { Image(systemName: "fan") }
                }
                .font(.system(size: 12))
                .frame(maxWidth: 460, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Acknowledgements").font(ThermikFont.sectionTitle).foregroundStyle(.secondary)
                    Text("Hardware facts were learned from these open-source projects; no code was copied from GPL projects.")
                        .font(ThermikFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Self.acknowledgements, id: \.name) { a in
                        HStack {
                            Text(verbatim: a.name).font(.system(size: 12))
                            Spacer()
                            Text(verbatim: a.license).font(ThermikFont.mono).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
                .thermikCard()
                Text(verbatim: "© 2026 Thermik contributors").font(ThermikFont.caption).foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}
