// AppEnvironment.swift — Thermik (MIT). Composition root (stores + samplers). Created by Unit 0; OWNER: Unit 5.
// Construction order matters (dependencies flow downwards). Services that need the whole environment
// (SamplingCoordinator, MenuBarController, WindowManager, CSVLoggingService) are created by AppDelegate.
import Foundation
import ThermikCore

@MainActor final class AppEnvironment {
    let isDemo: Bool
    let settings: SettingsStore
    let events: EventLogStore
    let router: AppRouter
    let visibility: VisibilityTracker
    let helper: HelperManager
    let sensors: SensorStore
    let system: SystemStore
    let history: HistoryStore
    let fans: FanStore
    let alerts: AlertStore
    let diagnostics: DiagnosticsStore
    let sensorSampler: any SensorSampling
    let systemSampler: any SystemSampling

    /// The running app's environment, for entry points the system calls without one (App Intents, `thermik://`
    /// links). Set once by `init`; there is exactly one environment per process.
    private(set) static var current: AppEnvironment?

    /// `demo == true` with launch argument `-ThermikDemo YES` (synthetic data, mock helper; works on any Mac).
    init(demo: Bool) {
        isDemo = demo
        settings = SettingsStore()
        events = EventLogStore()
        router = AppRouter()
        visibility = VisibilityTracker()
        helper = HelperManager(demo: demo)
        sensorSampler = demo ? DemoSensorSampler() : SensorSampler()
        systemSampler = demo ? DemoSystemSampler() : SystemSampler()
        sensors = SensorStore(settings: settings)
        system = SystemStore()
        system.attach(events: events)
        history = HistoryStore(sensors: sensors)
        fans = FanStore(settings: settings, sensors: sensors, system: system, helper: helper, events: events, router: router)
        history.attach(fans: fans, system: system)
        alerts = AlertStore(settings: settings, sensors: sensors, fans: fans, system: system, events: events, router: router)
        diagnostics = DiagnosticsStore(sensors: sensors, fans: fans, system: system, helper: helper, sampler: systemSampler,
                                       events: events)
        alerts.attach(diagnostics: diagnostics, systemSampler: systemSampler)
        Self.current = self
    }

    static var launchedInDemoMode: Bool { UserDefaults.standard.bool(forKey: "ThermikDemo") }
}
