// AlertStore.swift — Thermik (MIT). STUB by Unit 0; OWNER: Unit 6 (AlertEngine + NotificationService). Surface FROZEN.
import Foundation
import Observation
import ThermikCore

enum NotificationAuthorization: Sendable, Equatable { case unknown, notDetermined, denied, authorized, provisional }

@MainActor @Observable final class AlertStore: TickConsumer {
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let sensors: SensorStore
    @ObservationIgnored let fans: FanStore
    @ObservationIgnored let system: SystemStore
    @ObservationIgnored let events: EventLogStore
    @ObservationIgnored let router: AppRouter

    /// Raised/cleared alert events, newest last (capacity 500).
    private(set) var recent: [AlertEvent] = []
    private(set) var authorization: NotificationAuthorization = .unknown
    /// Rules currently in the raised state.
    private(set) var activeRuleIDs: Set<UUID> = []
    @ObservationIgnored private(set) weak var diagnostics: DiagnosticsStore?
    @ObservationIgnored private(set) var systemSampler: (any SystemSampling)?

    init(settings: SettingsStore, sensors: SensorStore, fans: FanStore, system: SystemStore, events: EventLogStore, router: AppRouter) {
        self.settings = settings; self.sensors = sensors; self.fans = fans; self.system = system; self.events = events; self.router = router
    }

    /// Wired by AppEnvironment after DiagnosticsStore exists (stalledFans input; topProcesses for P1 bodies).
    func attach(diagnostics: DiagnosticsStore, systemSampler: any SystemSampling) {
        self.diagnostics = diagnostics; self.systemSampler = systemSampler
    }

    var rules: [AlertRule] { settings.alertRules }
    var alertsToday: Int { recent.filter { $0.kind == .raised && Calendar.current.isDateInToday($0.date) }.count }
    var hasActiveAlert: Bool { !activeRuleIDs.isEmpty }

    func consume(_ tick: Tick) {}
    func add(_ rule: AlertRule) { settings.alertRules.append(rule) }
    func update(_ rule: AlertRule) { if let i = settings.alertRules.firstIndex(where: { $0.id == rule.id }) { settings.alertRules[i] = rule } }
    func remove(_ id: UUID) { settings.alertRules.removeAll { $0.id == id } }
    func resetToDefaults() { settings.alertRules = AlertRule.defaultRules }
    func requestAuthorization() async {}
    func sendTestNotification() async {}
    func snooze(for seconds: TimeInterval) { settings.alertsSnoozedUntil = Date().addingTimeInterval(seconds) }
}
