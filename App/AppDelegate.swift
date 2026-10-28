// AppDelegate.swift — Thermik (MIT). Wiring by Unit 0; OWNER: Unit 5 (lifecycle, single instance, launch at login,
// sleep/wake orchestration, termination). The consumer ORDER below is part of the contract (SPEC §2.3.3).
// Lifecycle (SPEC §2.3.5):
//   launch  single-instance guard → environment → windows, status item ("—"), CSV logging → helper.refresh() →
//           sensor + system discovery, boot history → sampling loop → onboarding if needed
//   sleep   pause sampling → fans to System (the helper does it too) → event
//   wake    event → samplers reopen / drop baselines (3 s post-wake window) → resume (first tick restarts the
//           filters) → fans re-apply after 3 s (FanStore)
//   quit    stop sampling → fans to System (bounded 2 s) → flush and close the CSV log (bounded 2 s). SIGTERM and
//           SIGINT take the same path.
import AppKit
import os
import ThermikCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var env: AppEnvironment!
    private var sampling: SamplingCoordinator!
    private var menuBar: MenuBarController!
    private var windows: WindowManager!
    private var logging: CSVLoggingService!
    private let power = PowerEventMonitor()
    private var urlRouter: URLRouter?
    /// Links that arrived before sensor discovery finished (the app was launched by a `thermik://` URL).
    private var pendingURLs: [URL] = []
    private var isReady = false
    private var isTerminating = false
    private var fansReleased = false
    /// Bumped on every sleep: a wake sequence still awaiting the samplers must not resume after a newer sleep.
    private var sleepGeneration = 0
    private var signalSources: [any DispatchSourceSignal] = []
    private var activationObserver: (any NSObjectProtocol)?
    private let log = Logger(subsystem: "app.thermik.Thermik", category: "lifecycle")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before ANY state exists: no environment, no status item, no sampler, no helper connection.
        SingleInstance.exitIfAnotherInstanceIsRunning()
    }

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
        #if DEBUG
        installDebugMenu()
        #endif
        menuBar.install()
        // FIXED consumer order: stores first, then engines that read them, then outputs.
        sampling = SamplingCoordinator(env: env, consumers: [env.sensors, env.system, env.history, env.fans,
                                                             env.alerts, env.diagnostics, logging, menuBar])
        env.router.requestTick = { [weak self] in self?.sampling.requestTickSoon() }
        power.onEvent = { [weak self] e in self?.handle(e) }
        power.start()
        urlRouter = URLRouter(env: env)
        LaunchAtLogin.shared.bind(to: env.settings)
        HotKeys.shared.start(settings: env.settings, handlers: [
            .showMainWindow: { [weak self] in self?.env.router.showMain(nil) },
            .togglePopover: { [weak self] in
                guard let env = self?.env else { return }
                env.visibility.popoverOpen ? env.router.closePopover() : env.router.openPopover()
            },
        ])
        installSignalHandlers()
        activationObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.activateNotification, object: SingleInstance.bundleID, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.env.router.showMain(nil) }       // a second launch → show this instance
        }
        env.events.record(.appLaunched(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
        log.info("launched (demo \(env.isDemo, privacy: .public))")
        Task { @MainActor in
            await env.helper.refresh()
            await sampling.start()
            if !env.settings.onboardingCompleted { env.router.showOnboarding() }
            isReady = true
            let urls = pendingURLs
            pendingURLs.removeAll()
            urls.forEach { urlRouter?.handle($0) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let links = urls.filter { $0.scheme?.lowercased() == URLRouter.scheme }
        guard isReady, let urlRouter else {
            pendingURLs.append(contentsOf: links)
            return
        }
        links.forEach { urlRouter.handle($0) }
    }

    private func handle(_ e: PowerEvent) {
        switch e {
        case .willSleep:
            sleepGeneration &+= 1
            sampling.pause(); env.fans.systemWillSleep(); env.events.record(.systemWillSleep)
            Task { await env.sensorSampler.willSleep() }
        case .didWake:
            env.events.record(.systemDidWake)
            let generation = sleepGeneration
            Task { @MainActor in
                await env.sensorSampler.didWake(); await env.systemSampler.didWake()
                guard generation == sleepGeneration else {
                    log.info("wake sequence superseded by a newer sleep")
                    return
                }
                sampling.resume(afterWake: true); env.fans.systemDidWake()
            }
        case .powerSourceChanged:
            sampling.powerSourcesChanged()
        case .willPowerOff, .screensDidSleep, .screensDidWake, .lowPowerModeChanged:
            // Logged by PowerEventMonitor. Logout/shutdown quits through applicationShouldTerminate (a cancelled
            // logout must not leave sampling paused); the cadence ignores display sleep and Low Power Mode.
            break
        }
    }

    // MARK: Termination

    /// Synchronous and bounded, then .terminateNow. A .terminateLater reply needs a main-queue job, and AppKit waits
    /// for it in a nested run loop that cannot drain the main queue when terminate was called under a main-queue block
    /// (a signal handler, an alert run modally from a Task): the quit hung forever.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard env != nil, !isTerminating else { return .terminateNow }
        isTerminating = true
        sampling?.stop()
        releaseFans()
        logging?.closeBlocking(timeout: 2)
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseFans()                                          // no-op when applicationShouldTerminate ran
        power.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windows.showMain(nil) }
        return true
    }

    /// Fans back to System, once (bounded 2 s inside FanStore).
    private func releaseFans() {
        guard !fansReleased, let env else { return }
        fansReleased = true
        env.fans.prepareForTermination()
    }

    /// SIGTERM (`kill`, launchd) and SIGINT (Ctrl-C in a terminal) quit through applicationShouldTerminate, so the
    /// fans are handed back before the process exits. Handled off the main queue and passed to the main run loop in
    /// common modes: a main-queue handler waits behind the running main-queue block, e.g. an alert run modally from a
    /// Task, until that alert is closed.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler { @Sendable in          // @Sendable: not main-actor isolated (it runs off main)
                RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Quits and starts this bundle again once this process has exited (language change, reset to defaults).
    /// The waiting shell gives up after 30 s.
    static func relaunch() {
        let script = "i=0; while /bin/kill -0 \"$0\" 2>/dev/null && [ $i -lt 150 ]; do /bin/sleep 0.2; i=$((i+1)); done; "
            + "/usr/bin/open \"$1\"" + (AppEnvironment.current?.isDemo == true ? " --args -ThermikDemo YES" : "")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do { try p.run() } catch {
            Logger(subsystem: "app.thermik.Thermik", category: "lifecycle")
                .error("relaunch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    #if DEBUG
    // Developer-only menu (DEBUG builds; not user-facing, so not localized).
    private func installDebugMenu() {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Debug")
        let dump = NSMenuItem(title: "Dump History Stats", action: #selector(dumpHistoryStats(_:)), keyEquivalent: "")
        dump.target = self
        menu.addItem(dump)
        item.submenu = menu
        NSApp.mainMenu?.addItem(item)
    }

    @objc private func dumpHistoryStats(_ sender: Any?) {
        let summary = env.history.debugSummary()
        log.notice("history: \(summary, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "History"
        alert.informativeText = summary
        alert.runModal()
    }
    #endif
}

/// SPEC §5 Unit 5: one Thermik per user session. A second launch (another copy, demo or not) shows the running
/// instance's main window and exits before it touches settings, the status item, the samplers or the helper.
@MainActor enum SingleInstance {
    static let bundleID = Bundle.main.bundleIdentifier ?? "app.thermik.Thermik"
    static let activateNotification = Notification.Name("app.thermik.Thermik.showMainWindow")

    static func exitIfAnotherInstanceIsRunning() {
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        // Two copies started together each see the other: only the younger one leaves.
        guard let running = others.first(where: { isOlder($0, than: me) }) else { return }
        Logger(subsystem: "app.thermik.Thermik", category: "lifecycle")
            .notice("another instance is running (pid \(running.processIdentifier, privacy: .public)); exiting")
        running.activate(from: me, options: [])
        DistributedNotificationCenter.default().postNotificationName(activateNotification, object: bundleID, userInfo: nil,
                                                                     deliverImmediately: true)
        exit(0)
    }

    private static func isOlder(_ a: NSRunningApplication, than b: NSRunningApplication) -> Bool {
        switch (a.launchDate, b.launchDate) {
        case let (x?, y?) where x != y: return x < y
        default: return a.processIdentifier < b.processIdentifier
        }
    }
}
