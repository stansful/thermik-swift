// AlertsPage.swift — Thermik (MIT). Unit 8. Alerts page (SPEC §4.6 W9, §2.10): notification-permission banner
// (→ System Settings › Notifications when denied), master switch and snooze state, the rule list (enable switch,
// subject, condition "above 95° for 30 s", cooldown) with an Add / Edit sheet (AlertRuleEditor.swift), "Send test
// notification", "Reset to defaults…" and the recent alerts list. Rule storage is AlertStore (Unit 6).
import SwiftUI
import ThermikCore

struct AlertsPage: View {
    @Bindable var model: MainWindowModel
    @Environment(AlertStore.self) private var alerts
    @Environment(SettingsStore.self) private var settings
    @Environment(SensorStore.self) private var sensors
    @State private var editing: AlertRule?
    @State private var confirmReset = false
    @State private var testSent = false

    var body: some View {
        PageScroll {
            banners
            PageCard(title: String(localized: "Rules"), symbol: "bell") {
                HStack(spacing: 8) {
                    Button { editing = AlertRule(subject: .aggregate(.cpuHottest), thresholdC: 95, forSeconds: 30) } label: {
                        Label { Text("Add Rule…") } icon: { Image(systemName: "plus") }
                    }
                    Button { sendTest() } label: { testSent ? Text("Sent") : Text("Send test notification") }
                    Button { confirmReset = true } label: { Text("Reset to Defaults…") }
                }
                .controlSize(.small)
            } content: {
                if alerts.rules.isEmpty {
                    Text("No rules. Add one to get a notification when a temperature stays too high.")
                        .font(ThermikFont.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(alerts.rules) { rule in
                            AlertRuleRow(rule: rule, isActive: alerts.activeRuleIDs.contains(rule.id),
                                         onEdit: { editing = rule }, onDelete: { alerts.remove(rule.id) })
                            if rule.id != alerts.rules.last?.id { Divider() }
                        }
                    }
                }
            }
            RecentAlertsCard()
        }
        .sheet(item: $editing) { rule in
            AlertRuleEditor(rule: rule, isNew: !alerts.rules.contains { $0.id == rule.id })
        }
        .confirmationDialog(Text("Reset alert rules to the defaults?"), isPresented: $confirmReset) {
            Button(role: .destructive) { alerts.resetToDefaults() } label: { Text("Reset Rules") }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: {
            Text("Your own rules are removed and the built-in rules are restored.")
        }
        .onAppear(perform: consumePendingSubject)
        .onChange(of: model.pendingAlertSubject) { _, _ in consumePendingSubject() }
        .onChange(of: alerts.pendingNewRuleSubject) { _, _ in consumePendingSubject() }
    }

    @ViewBuilder private var banners: some View {
        switch alerts.authorization {
        case .denied:
            StatusBanner(kind: .warning, symbol: "bell.slash",
                         text: String(localized: "Notifications are turned off for Thermik, so alerts cannot be shown.")) {
                Button { SystemSettingsLink.open(SystemSettingsLink.notifications) } label: { Text("Open Notification Settings") }
            }
        case .notDetermined, .unknown:
            StatusBanner(kind: .info, symbol: "bell.badge",
                         text: String(localized: "Allow notifications so Thermik can tell you when your Mac runs hot.")) {
                Button { Task { await alerts.requestAuthorization() } } label: { Text("Allow Alerts") }
            }
        case .authorized, .provisional:
            EmptyView()
        }
        if !settings.alertsEnabled {
            StatusBanner(kind: .warning, symbol: "bell.slash", text: String(localized: "Alerts are turned off.")) {
                Button { settings.alertsEnabled = true } label: { Text("Turn On") }
            }
        }
        if let until = settings.alertsSnoozedUntil, until > Date() {
            let time = until.formatted(date: .omitted, time: .shortened)
            StatusBanner(kind: .info, symbol: "moon.zzz", text: String(localized: "Alerts are snoozed until \(time).")) {
                Button { settings.alertsSnoozedUntil = nil } label: { Text("Resume") }
            }
        }
    }

    private func sendTest() {
        Task { @MainActor in
            await alerts.sendTestNotification()
            testSent = true
            try? await Task.sleep(for: .seconds(2))
            testSent = false
        }
    }

    /// "Set alert…" from the Sensors page (window model) or the popover (AlertStore): open the editor pre-filled for
    /// that subject.
    private func consumePendingSubject() {
        guard let subject = model.pendingAlertSubject ?? alerts.pendingNewRuleSubject else { return }
        model.pendingAlertSubject = nil
        alerts.pendingNewRuleSubject = nil
        let current: Double? = if case .sensor(let id) = subject { sensors.sensor(id)?.value } else { nil }
        let threshold = current.map { (($0 + 10) / 5).rounded(.up) * 5 } ?? 90
        editing = AlertRule(subject: subject, thresholdC: min(max(threshold, 40), 110), forSeconds: 10)
    }
}

// MARK: - Rule row

private struct AlertRuleRow: View {
    var rule: AlertRule
    var isActive: Bool
    var onEdit: () -> Void
    var onDelete: () -> Void
    @Environment(AlertStore.self) private var alerts
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { rule.enabled }, set: { var r = rule; r.enabled = $0; alerts.update(r) })) {
                Text(verbatim: title)
            }
            .toggleStyle(.thermikSwitch)
            .labelsHidden()
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if isActive {
                        Label { Text("Raised") } icon: { Image(systemName: "bell.badge.fill") }
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ThermikPalette.ink(0.88))
                    }
                    if rule.action == .setFansMax {
                        Image(systemName: "wind").font(.system(size: 10)).foregroundStyle(.secondary)
                            .help(Text("Sets the fans to Max when raised"))
                    }
                }
                Text(verbatim: AlertRuleText.condition(rule, unit: settings.effectiveUnit))
                    .font(ThermikFont.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onEdit) { Text("Edit…") }.controlSize(.small)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(Text("Delete rule"))
                .accessibilityLabel(Text("Delete rule"))
        }
        .padding(.vertical, 8)
        .opacity(rule.enabled ? 1 : 0.6)
        .contextMenu {
            Button(action: onEdit) { Text("Edit…") }
            Button(role: .destructive, action: onDelete) { Text("Delete rule") }
        }
    }

    private var title: String { rule.subject.title { sensors.sensor($0)?.displayName } }
}

/// Localized rule descriptions.
enum AlertRuleText {
    static func condition(_ r: AlertRule, unit: UnitTemperature) -> String {
        var parts: [String] = []
        let duration = r.forSeconds > 0 ? WindowFormat.duration(r.forSeconds) : nil
        if r.subject.isTemperature, let t = r.thresholdC {
            let temp = ThermikFormat.temp(t, unit: unit)
            parts.append(duration.map { String(localized: "above \(temp) for \($0)") } ?? String(localized: "above \(temp)"))
        } else if let duration {
            parts.append(String(localized: "for \(duration)"))
        } else {
            parts.append(String(localized: "as soon as it happens"))
        }
        parts.append(r.cooldownSeconds > 0 ? String(localized: "at most every \(WindowFormat.duration(r.cooldownSeconds))")
                                           : String(localized: "every time"))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Recent alerts

private struct RecentAlertsCard: View {
    @Environment(AlertStore.self) private var alerts
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        PageCard(title: String(localized: "Recent alerts"), symbol: "clock.arrow.circlepath") {
            let recent = Array(alerts.recent.suffix(50).reversed())
            if recent.isEmpty {
                Text("No alerts yet.").font(ThermikFont.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recent) { e in
                        HStack(spacing: 8) {
                            Image(systemName: e.kind == .raised ? "bell.badge.fill" : "checkmark.circle")
                                .foregroundStyle(e.kind == .raised ? AnyShapeStyle(ThermikPalette.ink(0.88)) : AnyShapeStyle(.secondary))
                            Text(verbatim: e.subject.title { sensors.sensor($0)?.displayName }).font(.system(size: 12)).lineLimit(1)
                            if let v = e.value {
                                Text(verbatim: ThermikFormat.temp(v, unit: settings.effectiveUnit, decimals: 1)).font(ThermikFont.valueSmall)
                            }
                            Spacer()
                            Text(verbatim: WindowFormat.dateTime(e.date)).font(ThermikFont.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
