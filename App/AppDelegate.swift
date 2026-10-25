// AppDelegate.swift — Thermik (MIT). Wiring by Unit 0; OWNER: Unit 5 (lifecycle, single instance, launch at login,
// sleep/wake orchestration, termination). The consumer ORDER below is part of the contract (SPEC §2.3.3).
import AppKit
import ThermikCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var env: AppEnvironment!
    private var sampling: SamplingCoordinator!
    private var menuBar: MenuBarController!
    private var windows: WindowManager!
    private var logging: CSVLoggingService!
    private let power = PowerEventMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment(demo: AppEnvironment.launchedInDemoMode)
        self.env = env
        windows = WindowManager(env: env)
        menuBar = MenuBarController(env: env)
        logging = CSVLoggingService(settings: env.settings, sensors: env.sensors, fans: env.fans, system: env.system, events: env.events)
        env.router.showMain = { [weak self] r in self?.windows.showMain(r) }
        env.router.showSettings = { [weak self] t in self?.windows.showSettings(t) }
        env.router.showOnboarding = { [weak self] in self?.windows.showOnboarding() }
        NSApp.mainMenu = MainMenu.make(router: env.router)
        menuBar.install()
        // FIXED consumer order: stores first, then engines that read them, then outputs.
        sampling = SamplingCoordinator(env: env, consumers: [env.sensors, env.system, env.history, env.fans,
                                                             env.alerts, env.diagnostics, logging, menuBar])
        env.router.requestTick = { [weak self] in self?.sampling.requestTickSoon() }
        power.onEvent = { [weak self] e in self?.handle(e) }
        power.start()
        env.events.record(.appLaunched(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
        Task { @MainActor in
            await env.helper.refresh()
            await sampling.start()
            if !env.settings.onboardingCompleted { env.router.showOnboarding() }
        }
    }

    private func handle(_ e: PowerEvent) {
        switch e {
        case .willSleep:
            sampling.pause(); env.fans.systemWillSleep(); env.events.record(.systemWillSleep)
            Task { await env.sensorSampler.willSleep() }
        case .didWake:
            env.events.record(.systemDidWake)
            Task { @MainActor in
                await env.sensorSampler.didWake(); await env.systemSampler.didWake()
                sampling.resume(afterWake: true); env.fans.systemDidWake()
            }
        default: break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        env?.fans.prepareForTermination()          // fans back to System (bounded 2 s)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windows.showMain(nil) }
        return true
    }
}
