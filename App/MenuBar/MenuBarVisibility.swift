//  MenuBarVisibility.swift — Thermik (MIT). OWNER: Unit 7. Hidden / notch detection for the status item (SPEC §4.4 B5,
//  FEAT §9.3): macOS silently drops items that do not fit (behind the camera notch, crowded menu bar) and, on 26+,
//  items the user switched off in System Settings › Menu Bar. Detection is event-driven (no polling):
//  2 s after launch, on screen-parameter and Space changes, on app activation (wide app menus push items away), on
//  occlusion changes of the item's window and on `isVisible` (KVO; ⌘-drag removal). Hidden for > 10 s → one hint per
//  launch. While the menu bar itself is out of sight (full-screen Space, auto-hidden menu bar, locked screen, displays
//  asleep) every item's window is occluded, so that says nothing about ours: no verdict, and no hidden time counted.
import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "app.thermik.Thermik", category: "menubar")

/// Why the item is not visible (diagnostics / hint text).
enum MenuBarHiddenReason: String, Sendable {
    case removed        // isVisible == false (⌘-dragged out, or "Allow in the Menu Bar" off)
    case occluded       // window not visible (no room)
    case notch          // intersects the camera housing
    case offScreen      // pushed beyond the screen edge
}

@MainActor final class MenuBarVisibility {
    private weak var status: StatusItemController?
    private let settings: SettingsStore
    private var observers: [any NSObjectProtocol] = []
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var visibleObservation: NSKeyValueObservation?
    private var occlusionObserver: (any NSObjectProtocol)?
    private var observedWindow: NSWindow?
    private var pending: DispatchWorkItem?
    private var hiddenSince: Date?
    private var screensAsleep = false
    private var sessionInactive = false          // fast user switching: another user's session is on the console
    private var warnedThisLaunch = false
    private var hintWindow: NSPanel?
    private(set) var reason: MenuBarHiddenReason?
    /// Called whenever the visibility verdict changes (first-run hint waits for a visible item).
    var onChange: ((MenuBarHiddenReason?) -> Void)?

    static let hiddenGrace: TimeInterval = 10

    init(status: StatusItemController, settings: SettingsStore) {
        self.status = status
        self.settings = settings
    }

    var isHidden: Bool { reason != nil }

    func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 1) }
        })
        let wc = NSWorkspace.shared.notificationCenter
        // Entering / leaving a full-screen Space switches the active Space (the menu bar hides / returns).
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule(after: 1) }
            })
        }
        let suspend: [(Notification.Name, @MainActor @Sendable (MenuBarVisibility) -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, { $0.screensAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.screensAsleep = false }),
            (NSWorkspace.sessionDidResignActiveNotification, { $0.sessionInactive = true }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { $0.sessionInactive = false }),
        ]
        for (name, apply) in suspend {
            workspaceObservers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self)
                    self.schedule(after: 2)
                }
            })
        }
        if let item = status?.item {
            visibleObservation = item.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.schedule(after: 0.5) }
            }
        }
        schedule(after: 2)
    }

    /// Coalesced re-check.
    func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluate() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func evaluate() {
        pending = nil
        guard let status else { return }
        watchOcclusion(of: status.item.button?.window)
        let r = Self.hiddenReason(status)
        // Occluded / off screen / behind the notch only count while the menu bar is shown. Otherwise keep the last
        // verdict and restart the grace period when the bar is back (its return changes the item window's occlusion,
        // which re-evaluates). A removed item (`isVisible == false`) is a verdict on its own.
        if let r, r != .removed, menuBarConcealed(status) {
            if hiddenSince != nil { log.info("menu bar not shown (\(r.rawValue) ignored); hidden time reset") }
            hiddenSince = nil
            return
        }
        if r != reason {
            reason = r
            log.info("menu bar item visibility: \(r?.rawValue ?? "visible")")
            onChange?(r)
        }
        guard r != nil else { hiddenSince = nil; return }
        let now = Date()
        if hiddenSince == nil { hiddenSince = now }
        let elapsed = now.timeIntervalSince(hiddenSince ?? now)
        if elapsed >= Self.hiddenGrace {
            warnIfNeeded()
        } else {
            schedule(after: Self.hiddenGrace - elapsed + 0.25)
        }
    }

    /// Hidden means `!isVisible`, an occluded item window, a window pushed off the screen, or one that intersects
    /// the notch (`notchRect(of:)`, macOS 12+ auxiliary areas).
    static func hiddenReason(_ status: StatusItemController) -> MenuBarHiddenReason? {
        guard status.item.isVisible else { return .removed }
        guard let w = status.item.button?.window else { return .removed }
        if !w.occlusionState.contains(.visible) { return .occluded }
        guard let screen = w.screen else { return .offScreen }
        if w.frame.maxX <= screen.frame.minX || w.frame.minX < screen.frame.minX || w.frame.minX >= screen.frame.maxX { return .offScreen }
        if let notch = notchRect(of: screen), notch.intersects(w.frame.insetBy(dx: 1, dy: 0)) { return .notch }
        return nil
    }

    /// The menu bar is out of sight where the item lives: displays asleep, another session on the console, the screen
    /// locked, the bar slid up (auto-hide), no menu bar reserved on that screen (auto-hide "Always", or a full-screen
    /// Space), or another app's window covering the whole screen (full-screen Space, borderless full-screen game).
    private func menuBarConcealed(_ status: StatusItemController) -> Bool {
        if screensAsleep || sessionInactive || Self.screenLocked { return true }
        guard let w = status.item.button?.window else { return false }
        let column = NSScreen.screens.first { $0.frame.minX <= w.frame.midX && w.frame.midX < $0.frame.maxX }
        guard let screen = w.screen ?? column ?? NSScreen.main else { return false }
        if w.frame.minY >= screen.frame.maxY - 1 { return true }
        if screen.visibleFrame.maxY >= screen.frame.maxY - 1 { return true }
        return Self.fullScreenWindowCovers(screen)
    }

    private static var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true || session["kCGSSessionOnConsoleKey"] as? Bool == false
    }

    /// A normal-level window of another app spans the whole screen (window bounds need no Screen Recording permission;
    /// titles would). CG window bounds are global, top-left origin at the primary screen.
    private static func fullScreenWindowCovers(_ screen: NSScreen) -> Bool {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let f = screen.frame
        let target = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height).insetBy(dx: 1, dy: 1)
        let me = ProcessInfo.processInfo.processIdentifier
        return list.contains { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? pid_t != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return false }
            return rect.contains(target)
        }
    }

    private func watchOcclusion(of window: NSWindow?) {
        guard window !== observedWindow else { return }
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        observedWindow = window
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                   object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 0.5) }
        }
    }

    // MARK: Hint (one per launch; "Don't Warn Again" turns `menuBar.warnWhenHidden` off)

    private func warnIfNeeded() {
        guard settings.menuBar.warnWhenHidden, !warnedThisLaunch, hintWindow == nil, let reason else { return }
        warnedThisLaunch = true
        status?.onLikelyHidden?()
        showHint(reason)
    }

    /// Also used by the DEBUG menu to preview the hint.
    func showHint(_ reason: MenuBarHiddenReason) {
        hintWindow?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = MenuBarHiddenHint(
            reason: reason,
            currentStyle: settings.menuBar.style,
            canReAdd: status.map { !$0.item.isVisible } ?? false,
            onStyle: { [weak self] style in self?.apply(style: style) },
            onShowItem: { [weak self] in self?.reAddItem() },
            onOpenSettings: { [weak self] in Self.openMenuBarSettings(); self?.closeHint() },
            onNeverWarn: { [weak self] in self?.settings.menuBar.warnWhenHidden = false; self?.closeHint() },
            onDismiss: { [weak self] in self?.closeHint() })
        let host = NSHostingView(rootView: view.fixedSize())
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: vf.maxX - panel.frame.width - 16, y: vf.maxY - 12))
        }
        panel.orderFrontRegardless()
        hintWindow = panel
        log.info("hidden-item hint shown (\(reason.rawValue))")
    }

    private func closeHint() {
        hintWindow?.close()
        hintWindow = nil
    }

    private func apply(style: MenuBarStyle) {
        settings.menuBar.style = style
        closeHint()
        schedule(after: 2)
    }

    private func reAddItem() {
        status?.item.isVisible = true
        closeHint()
        schedule(after: 2)
    }

    /// macOS 26+: System Settings › Menu Bar (verify on 27); falls back to System Settings itself.
    static func openMenuBarSettings() {
        if #available(macOS 26.0, *),
           let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"),
           NSWorkspace.shared.open(url) { return }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Content of the hidden-item hint.
struct MenuBarHiddenHint: View {
    var reason: MenuBarHiddenReason
    var currentStyle: MenuBarStyle
    var canReAdd: Bool
    var onStyle: (MenuBarStyle) -> Void
    var onShowItem: () -> Void
    var onOpenSettings: () -> Void
    var onNeverWarn: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "menubar.rectangle").font(.system(size: 18)).foregroundStyle(.secondary)
                Text("Thermik's menu bar item is hidden").font(.system(size: 13, weight: .semibold))
            }
            Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can still open Thermik with its global keyboard shortcut, or by opening the app again from the Applications folder.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if canReAdd {
                    Button("Show in Menu Bar", action: onShowItem).keyboardShortcut(.defaultAction)
                }
                if currentStyle != .iconOnly { Button("Use Icon Only") { onStyle(.iconOnly) } }
                if currentStyle != .stacked { Button("Use Stacked") { onStyle(.stacked) } }
            }
            HStack(spacing: 8) {
                if #available(macOS 26.0, *) { Button("Open Menu Bar Settings…", action: onOpenSettings) }
                Spacer(minLength: 8)
                Button("Don't Warn Again", action: onNeverWarn)
                Button("OK", action: onDismiss).keyboardShortcut(canReAdd ? .cancelAction : .defaultAction)
            }
        }
        .controlSize(.small)
        .padding(16)
        .padding(.top, 8)
        .frame(width: 400)
    }

    private var explanation: String {
        switch reason {
        case .removed:
            String(localized: "It was removed from the menu bar, or it is turned off in System Settings › Menu Bar.")
        case .notch:
            String(localized: "It is behind the camera notch. A narrower style or fewer menu bar items make room for it.")
        case .occluded, .offScreen:
            String(localized: "There is not enough room in the menu bar. A narrower style or fewer menu bar items make room for it.")
        }
    }
}
