//  StatusItemController.swift — NSStatusItem + floating SwiftUI panel (MIT).
//  Chosen over SwiftUI MenuBarExtra because we need: image labels updated at 1 Hz, programmatic open (alerts),
//  right-click menu, multiple items, notch-occlusion detection, and (macOS 27) menu-bar keyboard navigation.
//  Panel (SPEC §4.5, DES §2.4): borderless non-activating NSPanel, 360 pt wide by default and user-resizable.
//  Automatic height = content ≤ 620 pt (and ≤ the screen), top edge pinned under the item; closes on Esc, outside click,
//  another of our windows taking key, or the
//  macOS 27 expanded-interface session ending. Content is built only while open (no SwiftUI work while closed).
import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "app.thermik.Thermik", category: "menubar")

@MainActor
final class StatusItemController: NSObject {
    let item: NSStatusItem
    let panelState = StatusPanelState()
    private let panel: StatusPanel
    private let renderer = MenuBarLabelRenderer()
    private var lastContent: MenuBarLabelContent?
    /// Backing scales of the attached screens when the current image was drawn (a 1× → 2× change needs a redraw).
    private var lastScales: [CGFloat] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?
    private var observers: [any NSObjectProtocol] = []
    private var revealWork: DispatchWorkItem?
    /// Fires if the item has been invisible (e.g. hidden behind the notch / by "Allow in the Menu Bar") for a while.
    var onLikelyHidden: (() -> Void)?
    var debugLog: ((String) -> Void)?
    /// Called after the panel opened / closed (VisibilityTracker.popoverOpen, cadence).
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    /// Right-click / ⌃-click menu (built fresh each time so checkmarks are current).
    var menuProvider: (() -> NSMenu?)?
    /// ⌥-click (SPEC §4.4: opens the main window).
    var onAlternateClick: (() -> Void)?
    /// The menu bar appearance changed (re-render a colour label with the right inks), or the displays changed
    /// (re-render for their backing scales, e.g. clamshell 1× external → lid open 2× built-in).
    var onAppearanceChange: (() -> Void)?
    private var lastSessionEnd = Date.distantPast
    private var openedAt = Date.distantPast
    /// True while the right-click menu tracks (performClick runs it modally). On 27+ the menu bar starts an
    /// expanded-interface session for that menu as well; it belongs to the menu (cancelling it closes the menu at once).
    private var showingMenu = false

    init<Content: View>(autosaveName: String, @ViewBuilder content: () -> Content) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let state = panelState
        panel = StatusPanel(content: AnyView(content()), state: state)
        super.init()
        item.autosaveName = autosaveName            // remembers the user's ⌘-drag position
        item.behavior = .removalAllowed             // user may ⌘-drag it out; the hidden-item hint offers "Show in Menu Bar"
        state.onContentSize = { [weak self] size in self?.contentSizeChanged(size) }
        state.requestClose = { [weak self] in self?.close() }
        panel.onCancel = { [weak self] in self?.close() }
        guard let button = item.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityTitle("Thermik")
        button.setAccessibilityHelp(String(localized: "Click for temperatures and fans. Right-click for fan modes and settings."))
        if #available(macOS 27.0, *) { item.expandedInterfaceDelegate = self }
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onAppearanceChange?() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onAppearanceChange?() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelResignedKey() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelState.set(key: true) }
        })
    }

    /// The status bar button's appearance (light/dark menu bar) for non-template drawing.
    var menuBarAppearance: NSAppearance.Name {
        let ap = item.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return ThermikPalette.isDark(ap) ? .darkAqua : .aqua
    }

    /// Kit API. Call at sensor cadence (1–2 s). Re-renders only when the visible text would change.
    func update(_ s: MenuBarSnapshot, style: MenuBarStyle, colored: Bool) {
        update(s, style: style, options: MenuBarRenderOptions(colored: colored, appearance: menuBarAppearance))
    }

    /// Full variant: colour, alert colour, colour-blind ramp. Cheap when nothing visible changed (one Hashable compare).
    func update(_ s: MenuBarSnapshot, style: MenuBarStyle, options: MenuBarRenderOptions) {
        let content = renderer.content(for: s, style: style, options: options)
        let scales = MenuBarLabelRenderer.screenScales
        let tooltip = s.accessibilityText ?? "Thermik"
        guard content != lastContent || scales != lastScales else { updateTooltip(tooltip); return }
        lastContent = content
        lastScales = scales
        let img = renderer.image(for: s, style: style, options: options, scales: scales)
        updateButton(image: img, tooltip: tooltip)
    }

    private func updateTooltip(_ tooltip: String) {
        if item.button?.toolTip != tooltip { item.button?.toolTip = tooltip }
    }

    private func updateButton(image: NSImage, tooltip: String) {
        item.button?.image = image
        item.button?.toolTip = tooltip
        item.button?.setAccessibilityLabel(tooltip)
    }

    private var sessionActive: Bool {
        if #available(macOS 27.0, *) { return item.expandedInterfaceSession != nil }
        return false
    }

    /// True while some part of the status item's window is on screen (false when hidden behind the notch or removed).
    var isOnScreen: Bool { item.isVisible && (item.button?.window?.occlusionState.contains(.visible) ?? false) }
    var isOpen: Bool { panelState.isOpen }

    // MARK: open / close

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if isSecondaryClick(event) { handleSecondaryClick(); return }
        if event?.modifierFlags.contains(.option) == true, let alt = onAlternateClick { close(); alt(); return }
        debugLog?("clicked; session=\(sessionActive)")
        if #available(macOS 27.0, *) {
            scheduleManualToggle()
            return
        }
        toggle()
    }

    private func isSecondaryClick(_ event: NSEvent?) -> Bool {
        event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
    }

    private func handleSecondaryClick() {
        // 27+: a secondary click on the item while our menu is open dismisses it, and its mouse-up arrives while
        // the menu's session is still ending; a new menu now would be closed by that ending session at once.
        if sessionActive, !panelState.isOpen { return }
        showContextMenu()
    }

    @available(macOS 27.0, *)
    private func scheduleManualToggle() {
        // On 27+ the menu-bar system may start an expanded-interface session for this click (delegate opens the
        // panel). If it did not (or just ended one), fall back to a manual toggle on the next runloop turn.
        DispatchQueue.main.async { [self] in
            guard !sessionActive, Date().timeIntervalSince(lastSessionEnd) > 0.3 else { return }
            toggle()
        }
    }

    func toggle() { panelState.isOpen ? close() : open() }

    func open() {
        guard !panelState.isOpen else { panel.makeKeyAndOrderFront(nil); return }
        preparePanelForOpening()
        presentPreparedPanel()
        scheduleReveal(after: 0.12)               // fallback if no size report arrives (size unchanged)
        installMonitors()
        onOpen?()
        log.debug("popover opened")
    }

    private func preparePanelForOpening() {
        let screen = anchorScreen
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panelState.set(maxHeight: min(ThermikMetrics.popoverMaxHeight, max(visible.height - 16, 200)))
        panel.anchor = anchorPoint(in: visible)
        panel.visibleArea = visible
        // Show transparent at the last known size; the content reports its real size within a frame (then we reveal).
        // Building the content only while open keeps the closed popover at zero SwiftUI cost.
        panel.alphaValue = 0
        openedAt = Date()
        panel.placeAtAnchor(size: panel.lastContentSize)
    }

    private func presentPreparedPanel() {
        panelState.set(open: true)
        panel.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
    }

    func close() {
        guard panelState.isOpen || panel.isVisible else { return }
        revealWork?.cancel(); revealWork = nil
        panel.orderOut(nil)
        panelState.set(open: false)
        panelState.set(key: false)
        item.button?.highlight(false)
        removeMonitors()
        if #available(macOS 27.0, *) { item.expandedInterfaceSession?.cancel() }
        onClose?()
        log.debug("popover closed")
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard panelState.isOpen, size.width > 1, size.height > 1 else { return }
        panel.place(size: size)
        // Reveal once the size has settled (the list measures itself one layout pass after the first report).
        if panel.alphaValue < 1 { scheduleReveal(after: 0.04) }
    }

    private func scheduleReveal(after delay: TimeInterval) {
        revealWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.revealPanel() }
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func revealPanel() {
        guard panelState.isOpen else { return }
        revealWork = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.alphaValue = 1; return }
        animateReveal()
    }

    private func animateReveal() {
        let panel = self.panel
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// Screen of the status item; the main screen when the item is hidden (hotkey / programmatic open).
    private var anchorScreen: NSScreen? {
        if isOnScreen, let s = item.button?.window?.screen { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Top-centre point the panel hangs from: under the button, or the top-right corner when the item is hidden.
    private func anchorPoint(in visible: NSRect) -> NSPoint {
        if isOnScreen, let button = item.button, let win = button.window {
            let r = win.convertToScreen(button.convert(button.bounds, to: nil))
            return NSPoint(x: r.midX, y: min(r.minY, visible.maxY) - 4)
        }
        return NSPoint(x: visible.maxX - ThermikMetrics.popoverWidth / 2 - 8, y: visible.maxY - 4)
    }

    private func installMonitors() {
        removeMonitors()
        installGlobalMonitor()
        installLocalMonitor()
    }

    private func installGlobalMonitor() {
        // Clicks in other apps.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func installLocalMonitor() {
        // Clicks in our other windows (main window, settings) — the status item button itself toggles via clicked().
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.closeForLocalEvent(event) }
            return event
        }
    }

    private func closeForLocalEvent(_ event: NSEvent) {
        // Menus (context menus opened from the panel) live at or above the pop-up menu level: ignore them.
        guard let w = event.window,
              w !== panel,
              w !== item.button?.window,
              !(w is StatusPanel),
              w.level.rawValue < NSWindow.Level.popUpMenu.rawValue else { return }
        close()
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    private func panelResignedKey() {
        panelState.set(key: false)
        // Key status moved to another of OUR windows (main window) or to another app (⌘-Tab, admin prompt): close, as a
        // menu would. Menus/context menus opened from the panel do not take key status. A resign right after opening
        // (window-server ordering on the very first show) is ignored.
        guard panelState.isOpen, Date().timeIntervalSince(openedAt) > 0.25 else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.closeIfPanelStillResigned() }
        }
    }

    private func closeIfPanelStillResigned() {
        guard panelState.isOpen, NSApp.keyWindow !== panel else { return }
        close()
    }

    private func showContextMenu() {
        close()
        guard let m = menuProvider?() else { return }
        item.menu = m
        showingMenu = true
        item.button?.performClick(nil)   // shows the menu, attached to the status item; returns once it closed
        showingMenu = false
        item.menu = nil                  // restore left-click → panel
    }
}

@available(macOS 27.0, *)
extension StatusItemController: NSStatusItemExpandedInterfaceDelegate {
    nonisolated func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        MainActor.assumeIsolated {
            beginExpandedInterfaceSession()
        }
    }

    private func beginExpandedInterfaceSession() {
        debugLog?("didBegin session; menu=\(showingMenu)")
        // The session of our own right-click menu (showContextMenu): leave it to the menu. NSApp.currentEvent is
        // no help here: it is whatever event came last (often the right mouse-up, sometimes a stale key-down).
        if showingMenu { return }
        // A secondary click must still show the context menu, not the panel.
        if let e = NSApp.currentEvent, e.type == .rightMouseDown || e.type == .rightMouseUp || e.modifierFlags.contains(.control) {
            item.expandedInterfaceSession?.cancel()
            return
        }
        open()
    }
    nonisolated func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        MainActor.assumeIsolated {
            debugLog?("didEnd session animated=\(animated)")
            lastSessionEnd = Date()
            if panelState.isOpen { close() }
        }
    }
}

extension Notification.Name { static let thermikOpenMainWindow = Notification.Name("thermik.openMainWindow") }
