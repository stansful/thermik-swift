// WindowManager.swift — Thermik (MIT). Basic version by Unit 0; OWNER: Unit 8. AppKit-managed windows hosting
// SwiftUI (deterministic from a menu-bar agent; avoids SwiftUI Settings-scene/openWindow pitfalls). Surface FROZEN.
import AppKit
import SwiftUI

@MainActor final class WindowManager: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private var main: NSWindow?
    private var settings: NSWindow?
    private var onboarding: NSWindow?

    init(env: AppEnvironment) { self.env = env }

    var isMainWindowVisible: Bool { main?.isVisible ?? false }

    func showMain(_ route: Route?) {
        if main == nil {
            let w = makeWindow(MainWindowRoot(initialRoute: route).thermikEnvironment(env),
                               contentSize: NSSize(width: 1080, height: 700),       // SPEC §4.6 default
                               style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            w.minSize = NSSize(width: 880, height: 560)
            // A saved frame wins; otherwise the window stays centred where makeWindow put it.
            _ = w.setFrameUsingName("ThermikMain")
            w.setFrameAutosaveName("ThermikMain")
            main = w
        }
        main?.title = env.system.machine?.marketingName ?? "Thermik"
        present(main)
        env.visibility.mainWindowVisible = true
    }

    func showSettings(_ tab: SettingsTab?) {
        if settings == nil {
            settings = makeWindow(SettingsRoot(initialTab: tab ?? .general).thermikEnvironment(env),
                                  contentSize: NSSize(width: 640, height: 480), style: [.titled, .closable])
        }
        present(settings)
        env.visibility.settingsOpen = true
    }

    func showOnboarding() {
        if onboarding == nil {
            onboarding = makeWindow(OnboardingView().thermikEnvironment(env),
                                    contentSize: NSSize(width: 560, height: 460), style: [.titled, .closable])
        }
        present(onboarding)
    }

    /// Creates a window at its final size and centres it once. `sizingOptions = [.minSize]`: SwiftUI only sets the
    /// minimum size. With the default options, the window first takes the hosting view's not-yet-laid-out size and
    /// grows only after it is on screen, so `center()` ran on the wrong size (windows ended up pinned under the menu
    /// bar, right of centre, partly off screen) and the main window shrank to its 880 × 560 minimum.
    private func makeWindow(_ root: some View, contentSize: NSSize, style: NSWindow.StyleMask) -> NSWindow {
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.minSize]
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
        if env.settings.showDockIconWhileWindowOpen { NSApp.setActivationPolicy(.regular) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === main { env.visibility.mainWindowVisible = false; env.visibility.visiblePage = nil }
        if w === settings { env.visibility.settingsOpen = false }
        let others = [main, settings, onboarding].compactMap { $0 }.filter { $0 !== w && $0.isVisible }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
