// FanStore.swift — Thermik (MIT). Minimal implementation by Unit 0 (monitoring only); OWNER: Unit 3, who adds the
// engine loop, helper commands, lease renewal, all-or-nothing, Max auto-revert, sleep/wake/quit handling
// (FanControlCoordinator.swift). Public surface FROZEN.
import Foundation
import Observation
import ThermikCore
import ThermikSMC

@MainActor @Observable final class LiveFan: Identifiable {
    let descriptor: FanDescriptor
    nonisolated var id: Int { descriptor.index }
    var displayName: String
    private(set) var actualRPM: Double = 0
    private(set) var targetRPM: Double?
    private(set) var modeValue: FanModeValue?
    private(set) var dutyCycle: Double?
    /// Apple Silicon parks fans at 0 rpm when cool: render "Off (macOS)", not an error.
    private(set) var isOff = true
    var minRPM: Double { descriptor.minRPM }
    var maxRPM: Double { descriptor.maxRPM }
    var percentOfMax: Double { maxRPM > 0 ? min(max(actualRPM / maxRPM, 0), 1) * 100 : 0 }

    init(descriptor: FanDescriptor, displayName: String) { self.descriptor = descriptor; self.displayName = displayName }

    func update(_ s: FanSnapshot) {
        actualRPM = s.actualRPM
        targetRPM = s.targetRPM > 0 ? s.targetRPM : nil
        modeValue = s.mode
        dutyCycle = s.dutyCycle
        isOff = s.isOff
    }
}

@MainActor @Observable final class FanStore: TickConsumer {
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let sensors: SensorStore
    @ObservationIgnored let system: SystemStore
    @ObservationIgnored let helper: HelperManager
    @ObservationIgnored let events: EventLogStore
    @ObservationIgnored let router: AppRouter

    private(set) var profile: FanHardwareProfile = .none
    private(set) var fans: [LiveFan] = []
    private(set) var mode: FanMode = .system
    private(set) var status: FanControlStatus = .monitoringOnly(.connecting)
    /// ◆ badge: Thermik currently holds manual control of at least one fan.
    private(set) var isOverriding = false
    private(set) var maxRevertDeadline: Date?
    private(set) var lastCommands: [Int: FanCommand] = [:]
    private(set) var foreignControllerName: String?
    /// Live operating point for the curve editor (engine input temperature, smoothed).
    private(set) var curveInputC: Double?

    init(settings: SettingsStore, sensors: SensorStore, system: SystemStore, helper: HelperManager, events: EventLogStore,
         router: AppRouter) {
        self.settings = settings; self.sensors = sensors; self.system = system; self.helper = helper; self.events = events
        self.router = router
    }

    var hasFans: Bool { !profile.fans.isEmpty }
    var config: FanUserConfig { settings.fans }
    /// Helper ready, fans present, no foreign controller.
    var canControl: Bool { hasFans && helper.isReady && foreignControllerName == nil }

    func load(profile: FanHardwareProfile, names: [String]?) {
        self.profile = profile
        fans = profile.fans.map { LiveFan(descriptor: $0, displayName: names?[safe: $0.index] ?? $0.name) }
        status = profile.fans.isEmpty ? .fanless : (helper.isReady ? .system : .monitoringOnly(helper.availability ?? .connecting))
    }

    func consume(_ tick: Tick) {
        guard let state = tick.sensors.fans else { return }
        for snap in state.fans { fans.first { $0.id == snap.index }?.update(snap) }
    }

    // MARK: Commands (Unit 3 implements; Unit 0 only records intent)
    func setMode(_ newMode: FanMode, reason: FanModeChangeReason = .user) {
        guard newMode != mode else { return }
        events.record(.fanModeChanged(FanModeChange(from: mode, to: newMode, reason: reason)))
        mode = newMode
        settings.fans.mode = newMode
    }
    func setFixedPercent(_ percent: Double, fan: Int?) {
        if let fan { settings.fans.fixedPercentPerFan[fan] = percent } else { settings.fans.fixedPercent = percent }
    }
    func setLinked(_ linked: Bool) { settings.fans.linked = linked }
    func applyCurve(_ curve: FanCurve, for power: PowerSourceKind) {
        if power == .battery { settings.fans.curveBattery = curve } else { settings.fans.curveAC = curve }
    }
    func applyPreset(_ id: FanPresetID) { applyCurve(FanPresets.curve(id), for: .ac) }
    /// "Reset to System": force-release everything (also clears state Thermik did not record).
    func resetToSystem() { setMode(.system, reason: .user) }
    /// P1: each fan to max for 10 s (user-initiated, helper required).
    func runFanTest() async {}
    func systemWillSleep() {}
    func systemDidWake() {}
    /// applicationWillTerminate: bounded synchronous restore (≤ 2 s).
    func prepareForTermination() { helper.client.resetAllFansBlocking(timeout: 2) }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
