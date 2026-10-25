//  StatusItemController.swift — NSStatusItem + floating SwiftUI panel (MIT).
//  Chosen over SwiftUI MenuBarExtra because we need: image labels updated at 1 Hz, programmatic open (alerts),
//  right-click menu, multiple items, notch-occlusion detection, and (macOS 27) menu-bar keyboard navigation.
import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    let item: NSStatusItem
    private let panel: StatusPanel
    private let renderer = MenuBarLabelRenderer()
    private var lastSnapshot: MenuBarSnapshot?
    private var lastStyle: MenuBarStyle?
    private var eventMonitor: Any?
    /// Fires if the item has been invisible (e.g. hidden behind the notch / by "Allow in the Menu Bar") for a while.
    var onLikelyHidden: (() -> Void)?
    var debugLog: ((String) -> Void)?
    private var lastSessionEnd = Date.distantPast

    init<Content: View>(autosaveName: String, @ViewBuilder content: () -> Content) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = StatusPanel(content: AnyView(content()))
        super.init()
        item.autosaveName = autosaveName            // remembers the user's ⌘-drag position
        item.behavior = .removalAllowed             // user may ⌘-drag it out; we offer "Show in menu bar" in Settings
        guard let button = item.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityTitle("Thermik")
        if #available(macOS 27.0, *) { item.expandedInterfaceDelegate = self }
    }

    /// Call at sensor cadence (1–2 s). Re-renders only when the visible text would change (renderer is cached too).
    func update(_ s: MenuBarSnapshot, style: MenuBarStyle, colored: Bool) {
        let rounded = MenuBarSnapshot(celsius: s.celsius.rounded(), rpm: s.rpm.map { ($0 / 10).rounded() * 10 },
                                      normalized: (s.normalized * 50).rounded() / 50, alert: s.alert)
        guard rounded != lastSnapshot || style != lastStyle else { return }
        lastSnapshot = rounded; lastStyle = style
        let scale = item.button?.window?.backingScaleFactor ?? 2
        item.button?.image = renderer.image(for: rounded, style: style, colored: colored, scale: scale)
        item.button?.toolTip = "Thermik — \(ThermikFormat.temp(s.celsius))"
    }

    private var sessionActive: Bool {
        if #available(macOS 27.0, *) { return item.expandedInterfaceSession != nil }
        return false
    }

    /// True while some part of the status item's window is on screen (false when hidden behind the notch or removed).
    var isOnScreen: Bool { item.isVisible && (item.button?.window?.occlusionState.contains(.visible) ?? false) }

    // MARK: open / close

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu(); return }
        debugLog?("clicked; session=\(sessionActive)")
        if #available(macOS 27.0, *) {
            // On 27+ the menu-bar system may start an expanded-interface session for this click (delegate opens the
            // panel). If it did not (or just ended one), fall back to a manual toggle on the next runloop turn.
            DispatchQueue.main.async { [self] in
                guard !sessionActive, Date().timeIntervalSince(lastSessionEnd) > 0.3 else { return }
                panel.isVisible ? close() : open()
            }
            return
        }
        panel.isVisible ? close() : open()
    }

    func open() {
        guard let button = item.button, let win = button.window else { return }
        let r = win.convertToScreen(button.convert(button.bounds, to: nil))
        panel.show(below: r)
        item.button?.highlight(true)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        panel.orderOut(nil)
        item.button?.highlight(false)
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        if #available(macOS 27.0, *) { item.expandedInterfaceSession?.cancel() }
    }

    private func showContextMenu() {
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "Open Thermik"), action: #selector(openMain), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "Quit Thermik"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
        item.button?.performClick(nil)   // shows the menu
        item.menu = nil                  // restore left-click → panel
    }
    @objc private func openMain() { NSApp.activate(); NotificationCenter.default.post(name: .thermikOpenMainWindow, object: nil) }
}

@available(macOS 27.0, *)
extension StatusItemController: NSStatusItemExpandedInterfaceDelegate {
    nonisolated func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        MainActor.assumeIsolated { debugLog?("didBegin session"); open() }
    }
    nonisolated func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        MainActor.assumeIsolated {
            debugLog?("didEnd session animated=\(animated)")
            lastSessionEnd = Date()
            panel.orderOut(nil); item.button?.highlight(false)
            if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        }
    }
}

extension Notification.Name { static let thermikOpenMainWindow = Notification.Name("thermik.openMainWindow") }

/// Borderless, non-activating panel that hosts the SwiftUI popover content. On macOS 26+ the SwiftUI root applies
/// `.glassEffect(.regular, in: .rect(cornerRadius: 18))`; on 14/15 an NSVisualEffectView(.popover) backs it.
final class StatusPanel: NSPanel {
    init(content: AnyView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: ThermikMetrics.popoverWidth, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: PanelChrome(content: content))
        host.sizingOptions = [.intrinsicContentSize]          // panel follows SwiftUI ideal size
        contentView = host
    }
    override var canBecomeKey: Bool { true }                  // text fields / keyboard nav inside the panel

    func show(below anchor: NSRect) {
        guard let host = contentView else { return }
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        var x = anchor.midX - size.width / 2
        if let vf = screen?.visibleFrame { x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8) }
        setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        makeKeyAndOrderFront(nil)
    }
}

struct PanelChrome: View {
    var content: AnyView
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26.0, *) {
            content.frame(width: ThermikMetrics.popoverWidth)
                .glassEffect(.regular, in: shape)
        } else {
            content.frame(width: ThermikMetrics.popoverWidth)
                .background { VisualEffect(material: .popover) }
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = material; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Notch geometry for the screen that hosts the status item (nil on screens without a notch).
@MainActor func notchRect(of screen: NSScreen) -> NSRect? {
    guard let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else { return nil }
    return NSRect(x: l.maxX, y: min(l.minY, r.minY), width: r.minX - l.maxX, height: max(l.height, r.height))
}
