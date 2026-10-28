// AlertStore.swift — Thermik (MIT). OWNER: Unit 6 (AlertEngine + NotificationService). Surface FROZEN; additions marked.
//
// Each tick (SPEC §2.10): build AlertInputs from the stores (smoothed values of VISIBLE temperature sensors read this
// tick, plus those of the sensors `.sensor` rules name, hidden or not; aggregates, DiagnosticsStore.stalledFans and
// the FanStore mode change of the PREVIOUS tick, pressure, the shutdown verdict once per boot, battery service),
// evaluate, record AppEvents, then notify for `.raised` unless alerts are off or snoozed. A rule action (Fans to Max)
// runs whenever alerts are on, snoozed or not: snoozing mutes notifications, not protection.
import AppKit
import Foundation
import Observation
import os
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

    static let capacity = 500
    /// UserDefaults key (ADDED, Unit 6): the boot an abnormal-shutdown alert was already shown for (once per boot,
    /// also across relaunches).
    static let lastShutdownAlertBootKey = "alerts.lastShutdownAlertBoot"

    @ObservationIgnored private var engine = AlertEngine()
    @ObservationIgnored private let notifications = NotificationService()
    @ObservationIgnored private var lastMode: FanMode?
    @ObservationIgnored private var lastTickDate: Date?
    @ObservationIgnored private var modeChange: FanModeChange?
    @ObservationIgnored private var shutdownChecked = false
    @ObservationIgnored private var pendingShutdownBoot: String?
    @ObservationIgnored private var groupCache: (signature: Int, map: [SensorID: DisplayGroup]) = (-1, [:])
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let log = Logger(subsystem: "app.thermik.Thermik", category: "alerts")

    init(settings: SettingsStore, sensors: SensorStore, fans: FanStore, system: SystemStore, events: EventLogStore, router: AppRouter) {
        self.settings = settings; self.sensors = sensors; self.fans = fans; self.system = system; self.events = events; self.router = router
        notifications.onAction = { [weak self] in self?.handle($0) }
        Task { [weak self] in await self?.refreshAuthorization() }
        // The user may change the permission in System Settings while Thermik runs.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshAuthorization() }
        })
    }

    /// Wired by AppEnvironment after DiagnosticsStore exists (stalledFans input; topProcesses for P1 bodies).
    func attach(diagnostics: DiagnosticsStore, systemSampler: any SystemSampling) {
        self.diagnostics = diagnostics; self.systemSampler = systemSampler
    }

    var rules: [AlertRule] { settings.alertRules }
    var alertsToday: Int { recent.filter { $0.kind == .raised && Calendar.current.isDateInToday($0.date) }.count }
    var hasActiveAlert: Bool { !activeRuleIDs.isEmpty }

    /// ADDED (Unit 6): true while `settings.alertsSnoozedUntil` lies in the future.
    var isSnoozed: Bool { settings.alertsSnoozedUntil.map { $0 > Date() } ?? false }

    /// ADDED (Unit 6): sensors the enabled rules need read every tick (SamplingCoordinator's `extra`): the sensor of a
    /// `.sensor` rule, the visible sensors of a `.group` rule, every visible sensor for `.anySensor`.
    var requiredSensorIDs: Set<SensorID> {
        var ids = Set<SensorID>()
        for rule in settings.alertRules where rule.enabled {
            switch rule.subject {
            case .sensor(let id): ids.insert(id)
            case .group(let g): ids.formUnion(sensors.sensors.filter { !$0.isHidden && $0.sensor.displayGroup == g }.map(\.id))
            case .anySensor: ids.formUnion(sensors.sensors.filter { !$0.isHidden }.map(\.id))
            default: break
            }
        }
        return ids
    }

    // MARK: Tick

    func consume(_ tick: Tick) {
        let rules = settings.alertRules
        let fired = engine.evaluate(rules: rules, inputs: makeInputs(now: tick.date))
        lastTickDate = tick.date
        let raised = engine.raisedRuleIDs
        if raised != activeRuleIDs { activeRuleIDs = raised }
        guard !fired.isEmpty else { return }

        recent.append(contentsOf: fired)
        if recent.count > Self.capacity { recent.removeFirst(recent.count - Self.capacity) }
        let byID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in fired {
            switch e.kind {
            case .raised:
                events.record(.alertRaised(ruleID: e.ruleID, subject: e.subject, value: e.value, sensorID: e.sensorID), date: e.date)
                log.info("alert raised: \(String(describing: e.subject), privacy: .public) \(e.value ?? .nan, privacy: .public)")
                if case .abnormalShutdown = e.subject, let boot = pendingShutdownBoot {
                    UserDefaults.standard.set(boot, forKey: Self.lastShutdownAlertBootKey)
                }
                if let rule = byID[e.ruleID] { react(to: e, rule: rule) }
            case .cleared:
                events.record(.alertCleared(ruleID: e.ruleID), date: e.date)
            }
        }
    }

    private func makeInputs(now: Date) -> AlertInputs {
        // Visible temperature sensors READ THIS TICK (a sensor not requested keeps an old value in its LiveSensor).
        let fresh = sensors.lastFrame?.values ?? [:]
        var values: [SensorID: Double] = [:]
        values.reserveCapacity(fresh.count)
        for s in sensors.sensors where !s.isHidden {
            guard let raw = fresh[s.id] else { continue }
            values[s.id] = s.value ?? raw
        }
        // A `.sensor` rule watches its sensor even when it is hidden (SamplingCoordinator reads it either way); these
        // values stay out of `sensorValues`, so `.anySensor` and `.group` still see visible sensors only.
        var named: [SensorID: Double] = [:]
        for rule in settings.alertRules where rule.enabled {
            guard case .sensor(let id) = rule.subject, values[id] == nil, let raw = fresh[id] else { continue }
            named[id] = sensors.sensor(id)?.value ?? raw
        }

        // Fan mode change since the previous tick (with the reason FanStore recorded).
        let mode = fans.mode
        modeChange = nil
        if let last = lastMode, last != mode {
            modeChange = FanModeChange(from: last, to: mode, reason: latestModeChangeReason() ?? .user)
        }
        lastMode = mode

        let pf = (system.battery?.permanentFailureStatus ?? 0) != 0
        let condition = system.appleBatteryHealth?.condition
        var inputs = AlertInputs(date: now, sensorValues: values, sensorGroups: sensorGroups(), aggregates: sensors.aggregates,
                                 stalledFans: diagnostics?.stalledFans ?? [], fanModeChange: modeChange, pressure: system.pressure,
                                 abnormalShutdown: shutdownInput(),
                                 batteryNeedsService: pf || condition == .serviceRecommended || condition == .permanentFailure)
        inputs.namedSensorValues = named
        return inputs
    }

    private func sensorGroups() -> [SensorID: DisplayGroup] {
        let signature = sensors.sensors.count &* 31 &+ (sensors.sensors.first?.id.hashValue ?? 0)
        if signature != groupCache.signature {
            groupCache = (signature, Dictionary(sensors.sensors.map { ($0.id, $0.sensor.displayGroup) }, uniquingKeysWith: { a, _ in a }))
        }
        return groupCache.map
    }

    private func latestModeChangeReason() -> FanModeChangeReason? {
        for e in events.events.reversed() {
            if let since = lastTickDate, e.date < since.addingTimeInterval(-1) { break }
            if case .fanModeChanged(let c) = e.payload { return c.reason }
        }
        return nil
    }

    /// The abnormal verdict exactly once: on the first evaluation that knows the verdict, and not again for a boot
    /// that was already alerted about (relaunches within one boot).
    private func shutdownInput() -> ShutdownVerdict? {
        guard !shutdownChecked, let verdict = system.shutdownVerdict else { return nil }
        shutdownChecked = true
        guard verdict.isAbnormal else { return nil }
        let boot = system.boot.flatMap { $0.bootSessionUUID ?? $0.bootTime.map { String(Int($0.timeIntervalSince1970)) } }
        if let boot, UserDefaults.standard.string(forKey: Self.lastShutdownAlertBootKey) == boot { return nil }
        pendingShutdownBoot = boot
        return verdict
    }

    // MARK: Reaction

    private func react(to e: AlertEvent, rule: AlertRule) {
        guard settings.alertsEnabled else { return }
        if rule.action == .setFansMax, fans.canControl, fans.mode != .max {
            fans.setMode(.max, reason: .notificationAction)
        }
        guard rule.channels.contains(.local), !isSnoozed else { return }
        let n = notification(for: e, rule: rule)
        let wantsTop = rule.subject.isTemperature
        Task { [weak self] in await self?.deliver(n, withTopProcesses: wantsTop) }
    }

    private func deliver(_ base: AlertNotification, withTopProcesses: Bool) async {
        var n = base
        if withTopProcesses, let sampler = systemSampler {
            let top = await sampler.topProcesses(limit: 3).map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
            if !top.isEmpty { n.body += " " + String(localized: "Top CPU: \(top).") }
        }
        if authorization == .notDetermined || authorization == .unknown { await requestAuthorization() }
        guard authorization == .authorized || authorization == .provisional else {
            log.info("alert notification suppressed: notifications not authorized")
            return
        }
        await notifications.post(n)
    }

    private func notification(for e: AlertEvent, rule: AlertRule) -> AlertNotification {
        let title: String, body: String
        var route: Route? = .alerts
        switch rule.subject {
        case .anySensor, .group, .sensor, .aggregate:
            let name = subjectName(e, rule)
            let value = e.value.map(temperature) ?? "—"
            title = String(format: String(localized: "%1$@ is %2$@", comment: "Alert title: subject name, temperature"), name, value)
            body = fanSummary()
            route = e.sensorID.map { .sensors($0) } ?? .overview
        case .fanStalled:
            let ids = diagnostics?.stalledFans ?? []
            let names = fans.fans.filter { ids.contains($0.id) }.map(\.displayName)
            let which = names.isEmpty ? String(localized: "Fan") : names.joined(separator: ", ")
            title = String(localized: "A fan is not spinning")
            body = String(localized: "\(which) reports 0 rpm although it should be running.")
            route = .fans
        case .fanModeChanged:
            title = String(localized: "Fan mode changed")
            if let c = modeChange {
                body = String(format: String(localized: "%1$@ → %2$@.", comment: "Fan mode change: old mode, new mode"), c.from.title, c.to.title)
            } else {
                body = fans.mode.title
            }
            route = .fans
        case .thermalPressure:
            title = String(localized: "Thermal pressure: \(system.pressure.title)")
            body = system.pressure >= .heavy ? String(localized: "macOS is throttling performance") + "."
                                             : String(localized: "Your Mac may slow down to cool itself.")
            route = .system
        case .abnormalShutdown:
            title = String(localized: "Your Mac shut down unexpectedly")
            body = String(localized: "Last shutdown: \((system.shutdownVerdict ?? .unknown).title). Details are on the Diagnostics page.")
            route = .diagnostics
        case .batteryService:
            title = String(localized: "Battery needs service")
            if (system.battery?.permanentFailureStatus ?? 0) != 0 {
                body = String(localized: "The battery reports a permanent failure.")
            } else {
                body = String(localized: "Battery health: \((system.appleBatteryHealth?.condition ?? .serviceRecommended).title).")
            }
            route = .battery
        }
        return AlertNotification(id: "alert.\(rule.id.uuidString)", title: title, body: body, threadID: rule.subject.description,
                                 route: route, offerFanActions: fans.canControl && rule.subject.isTemperature,
                                 soundName: rule.soundName ?? settings.alertSoundName)
    }

    private func subjectName(_ e: AlertEvent, _ rule: AlertRule) -> String {
        if let id = e.sensorID, let live = sensors.sensor(id) {
            if case .aggregate(let k) = rule.subject { return k.title }   // "CPU hottest", not the core that produced it
            return live.displayName
        }
        switch rule.subject {
        case .aggregate(let k): return k.title
        case .group(let g): return g.title
        case .sensor(let id): return id.key
        default: return String(localized: "A sensor")
        }
    }

    /// "62°" in the user's unit (Typography §4.12: no space before "°").
    private func temperature(_ celsius: Double) -> String {
        let v = Measurement(value: celsius, unit: UnitTemperature.celsius).converted(to: settings.effectiveUnit).value
        return v.formatted(.number.precision(.fractionLength(0))) + "°"
    }

    /// "Fans: Curve · 4 200 rpm." or the fanless sentence.
    private func fanSummary() -> String {
        guard fans.hasFans else { return String(localized: "Your Mac may slow down to cool itself.") }
        let spinning = fans.fans.filter { !$0.isOff }
        let speed: String
        if spinning.isEmpty {
            speed = String(localized: "Off", comment: "Fan is not spinning")
        } else {
            let rpm = (spinning.map(\.actualRPM).reduce(0, +) / Double(spinning.count)).formatted(.number.precision(.fractionLength(0)))
            speed = String(localized: "\(rpm) rpm")
        }
        let summary = [fans.mode.title, speed].joined(separator: " · ")
        return String(localized: "Fans: \(summary).")
    }

    private func handle(_ action: NotificationAction) {
        switch action {
        case .open(let route): router.showMain(route ?? .alerts)
        case .setFansMax:
            if fans.canControl { fans.setMode(.max, reason: .notificationAction) } else { router.showMain(.fans) }
        case .snooze1h: snooze(for: 3600)
        }
    }

    // MARK: Rules

    func add(_ rule: AlertRule) { settings.alertRules.append(rule); askIfNeeded(rule) }
    func update(_ rule: AlertRule) {
        if let i = settings.alertRules.firstIndex(where: { $0.id == rule.id }) { settings.alertRules[i] = rule; askIfNeeded(rule) }
    }
    func remove(_ id: UUID) { settings.alertRules.removeAll { $0.id == id } }
    func resetToDefaults() { settings.alertRules = AlertRule.defaultRules }

    /// ADDED: a new rule the Alerts page should open pre-filled in its editor ("Set Alert…" in the popover, which
    /// cannot reach the main window's model). The page clears it when it opens the editor.
    var pendingNewRuleSubject: AlertRule.Subject?

    /// ADDED: asks the Alerts page for a new rule on `subject`; the caller then shows the page (`router.showMain(.alerts)`).
    func requestNewRule(for subject: AlertRule.Subject) { pendingNewRuleSubject = subject }

    /// Authorization is requested when the first rule is enabled (or on onboarding step 3).
    private func askIfNeeded(_ rule: AlertRule) {
        guard rule.enabled, rule.channels.contains(.local), authorization == .notDetermined else { return }
        Task { [weak self] in await self?.requestAuthorization() }
    }

    // MARK: Notifications

    func requestAuthorization() async {
        let status = await notifications.requestAuthorization()
        if status != authorization { authorization = status }
    }

    private func refreshAuthorization() async {
        let status = await notifications.authorizationStatus()
        if status != authorization { authorization = status }
    }

    /// "Send test notification" (asks for permission on first use).
    func sendTestNotification() async {
        if authorization == .notDetermined || authorization == .unknown { await requestAuthorization() }
        guard authorization == .authorized || authorization == .provisional else {
            log.info("test notification not sent: notifications not authorized")
            return
        }
        await notifications.post(AlertNotification(id: "thermik.test", title: String(localized: "Thermik test notification"),
                                                   body: String(localized: "Notifications work. Alerts will look like this."),
                                                   threadID: "test", route: .alerts, offerFanActions: fans.canControl,
                                                   soundName: settings.alertSoundName))
    }

    /// ADDED (Unit 6): System Settings › Notifications › Thermik (when the permission was denied).
    func openNotificationSettings() { notifications.openSystemSettings() }

    func snooze(for seconds: TimeInterval) { settings.alertsSnoozedUntil = Date().addingTimeInterval(seconds) }
}
