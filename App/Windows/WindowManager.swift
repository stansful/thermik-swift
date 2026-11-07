// WindowManager.swift — Thermik (MIT). AppKit-managed windows hosting SwiftUI
// (deterministic from a menu-bar agent; avoids SwiftUI Settings-scene/openWindow pitfalls).
//
// Responsibilities (SPEC §4.6–4.8):
// - main window (NavigationSplitView, 1080 × 700 default, 880 × 560 minimum, frame autosave "ThermikMain"; Settings are
//   one of its pages, `showSettings` opens it there) and the onboarding window (560 × 460);
// - Dock icon + app menu while any of them is open (`.regular`, if settings.showDockIconWhileWindowOpen), back to
//   `.accessory` when the last one closes; the setting applies live;
// - VisibilityTracker: mainWindowVisible (visible, not miniaturized, not fully occluded), visiblePage,
//   inspectedSensor, settingsOpen (the Settings page is showing) — these drive the sampling cadence (§2.3.4);
// - every hosted root gets the design-system environment (ThermikWindowContent), like PopoverRoot does.
import AppKit
import os
import SwiftUI
import ThermikCore

@MainActor final class WindowManager: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private let model = MainWindowModel()
    private var main: NSWindow?
    private var onboarding: NSWindow?
    /// Last occlusion report for the main window (reset when it is presented: the first report arrives later).
    private var mainOccluded = false
    private var observers: [any NSObjectProtocol] = []
    private let log = Logger(subsystem: "app.thermik.Thermik", category: "windows")

    init(env: AppEnvironment) {
        self.env = env
        super.init()
        model.onVisibleChange = { [weak self] in self?.syncVisibility() }
        observeDockIconSetting()
    }

    /// Visible on screen (not closed, not miniaturized, not fully covered).
    var isMainWindowVisible: Bool {
        guard let main else { return false }
        return main.isVisible && !main.isMiniaturized && !mainOccluded
    }

    // MARK: Main window

    func showMain(_ route: Route?) {
        let w = main ?? makeMainWindow()
        if let route { model.open(route) }
        if model.page == .fans && !env.fans.hasFans && env.sensors.isLoaded { model.page = .overview }
        if w.isMiniaturized { w.deminiaturize(nil) }
        mainOccluded = false
        present(w)
        syncVisibility()
    }

    private func makeMainWindow() -> NSWindow {
        let root = ThermikWindowContent(tracksMainWindow: true) { MainWindowRoot(model: model) }.thermikEnvironment(env)
        let host = NSHostingController(rootView: root)
        configureMainHost(host)
        let w = makeWindow(host, contentSize: NSSize(width: 1080, height: 700),               // SPEC §4.6 default
                           style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        configureMainWindow(w)
        observeMainWindow(w)
        main = w
        return w
    }

    private func configureMainHost(_ host: NSHostingController<some View>) {
        host.sizingOptions = [.minSize]
        // SwiftUI owns the title (navigationTitle = marketing name) and the toolbar (history range, search, export).
        host.sceneBridgingOptions = [.title, .toolbars]
    }

    private func configureMainWindow(_ w: NSWindow) {
        w.minSize = NSSize(width: 880, height: 560)
        w.toolbarStyle = .unified
        w.title = env.system.machine?.marketingName ?? "Thermik"
        w.tabbingMode = .disallowed
        // A saved frame wins; otherwise the window stays centred where makeWindow put it.
        _ = w.setFrameUsingName("ThermikMain")
        w.setFrameAutosaveName("ThermikMain")
    }

    private func observeMainWindow(_ w: NSWindow) {
        observeMainOcclusion(w)
        observeMainMiniaturization(w)
    }

    private func observeMainOcclusion(_ w: NSWindow) {
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let w = self.main else { return }
                self.mainOccluded = !w.occlusionState.contains(.visible)
                self.syncVisibility()
            }
        })
    }

    private func observeMainMiniaturization(_ w: NSWindow) {
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncVisibility() }
            })
        }
    }

    /// Pushes the main window's state into VisibilityTracker (only real changes, so observers stay quiet).
    private func syncVisibility() {
        let v = env.visibility
        let visible = isMainWindowVisible
        if v.mainWindowVisible != visible { v.mainWindowVisible = visible }
        let page: Route.Page? = visible ? model.page : nil
        if v.visiblePage != page { v.visiblePage = page }
        let inspected = visible && model.page == .sensors && model.isInspectorShown ? model.selectedSensor : nil
        if v.inspectedSensor != inspected { v.inspectedSensor = inspected }
        let settingsShown = visible && model.page == .settings
        if v.settingsOpen != settingsShown { v.settingsOpen = settingsShown }
    }

    // MARK: Settings

    /// Settings are a page of the main window (one place for everything, no second window to manage).
    func showSettings(_ tab: SettingsTab?) {
        showMain(.settings(tab))
    }

    // MARK: Onboarding

    func showOnboarding() {
        if onboarding == nil { onboarding = makeOnboardingWindow() }
        present(onboarding)
    }

    private func makeOnboardingWindow() -> NSWindow {
        let root = ThermikWindowContent {
            OnboardingView(onFinish: { [weak self] in self?.onboarding?.close() })
        }.thermikEnvironment(env)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.minSize]
        let w = makeWindow(host, contentSize: NSSize(width: 560, height: 460), style: [.titled, .closable, .fullSizeContentView])
        configureOnboardingWindow(w)
        return w
    }

    private func configureOnboardingWindow(_ w: NSWindow) {
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.title = String(localized: "Welcome to Thermik")
        w.tabbingMode = .disallowed
    }

    // MARK: Shared

    /// Creates a window at its final size and centres it once. `sizingOptions = [.minSize]`: SwiftUI only sets the
    /// minimum size. With the default options, the window first takes the hosting view's not-yet-laid-out size and
    /// grows only after it is on screen, so `center()` ran on the wrong size (windows ended up pinned under the menu
    /// bar, right of centre, partly off screen) and the main window shrank to its 880 × 560 minimum.
    private func makeWindow(_ host: NSViewController, contentSize: NSSize, style: NSWindow.StyleMask) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: style, backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(contentSize)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        return w
    }

    private func present(_ w: NSWindow?) {
        guard let w else { return }
        if env.settings.showDockIconWhileWindowOpen, NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        updateActivationPolicy(closing: w)
        closeWindow(w)
        w.delegate = nil
        Task { @MainActor in _ = w }        // keep the window alive until AppKit has finished closing it
    }

    // Closed windows release their SwiftUI trees; the model keeps page / range / selection for the next window.
    private func closeWindow(_ w: NSWindow) {
        if w === main {
            closeMainWindow(w)
        } else if w === onboarding {
            onboarding = nil
        }
    }

    // Report hidden explicitly because isVisible is still true in windowWillClose. Free the unique autosave name now.
    private func closeMainWindow(_ w: NSWindow) {
        env.visibility.mainWindowVisible = false
        env.visibility.visiblePage = nil
        env.visibility.inspectedSensor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        w.saveFrame(usingName: "ThermikMain")
        w.setFrameAutosaveName("")
        env.visibility.settingsOpen = false
        main = nil
    }

    /// `.regular` while any Thermik window is on screen and the user wants the Dock icon; `.accessory` otherwise.
    private func updateActivationPolicy(closing: NSWindow? = nil) {
        let anyOpen = [main, onboarding].compactMap { $0 }.contains { $0 !== closing && $0.isVisible }
        let wanted: NSApplication.ActivationPolicy = anyOpen && env.settings.showDockIconWhileWindowOpen ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular { NSApp.activate() }
        log.debug("activation policy → \(wanted == .regular ? "regular" : "accessory", privacy: .public)")
    }

    /// Applies "Show Dock icon while a window is open" immediately (re-arms itself after every change).
    private func observeDockIconSetting() {
        withObservationTracking {
            _ = env.settings.showDockIconWhileWindowOpen
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateActivationPolicy()
                self?.observeDockIconSetting()
            }
        }
    }
}

/// Hosted window root: the stores come from `.thermikEnvironment(env)` (applied outside), the design-system values from
/// here: colour-blind ramp, Settings › Appearance › Animated effects and, for the main window, its visibility (effects
/// freeze while it is closed, miniaturized or fully covered; SPEC §4.10). PopoverRoot does the same for the popover.
struct ThermikWindowContent<Content: View>: View {
    var tracksMainWindow = false
    @ViewBuilder var content: Content
    @Environment(SettingsStore.self) private var settings
    @Environment(VisibilityTracker.self) private var visibility

    var body: some View {
        content.thermikDesignEnvironment(colorBlind: settings.colorBlindScale, animatedEffects: settings.animatedEffects,
                                         visible: tracksMainWindow ? visibility.mainWindowVisible : true)
    }
}
