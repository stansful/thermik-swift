// StatusPanel.swift — resizable floating SwiftUI panel (MIT).
import AppKit
import SwiftUI

/// Presentation state shared with the hosted SwiftUI content (`@Environment(StatusPanelState.self)`).
@MainActor @Observable final class StatusPanelState {
    /// True from `open()` until `close()`; the content tree exists only while true.
    private(set) var isOpen = false
    /// Automatic height budget, or the user-selected height after a manual resize.
    private(set) var maxHeight: CGFloat = ThermikMetrics.popoverMaxHeight
    /// User-selected size; retained while the panel is closed and until the app quits.
    private(set) var customSize: CGSize?
    /// The panel is key: keyboard focus is inside it.
    private(set) var isKey = false
    @ObservationIgnored weak var panel: StatusPanel?
    @ObservationIgnored var onContentSize: ((CGSize) -> Void)?
    /// Asks the controller to close the panel (row clicks, "Open Thermik", Esc inside text fields…).
    @ObservationIgnored var requestClose: () -> Void = {}

    func set(open: Bool) { if isOpen != open { isOpen = open } }
    func set(maxHeight h: CGFloat) {
        guard customSize == nil, maxHeight != h else { return }
        maxHeight = h
    }
    func set(key: Bool) { if isKey != key { isKey = key } }
    func set(customSize size: CGSize) { customSize = size; maxHeight = size.height }
    fileprivate func reportSize(_ s: CGSize) { onContentSize?(s) }
}

/// Borderless, non-activating panel that hosts the SwiftUI popover content. On macOS 26+ the SwiftUI root applies
/// `.glassEffect(.regular, in: .rect(cornerRadius: 18))`; on 14/15 an NSVisualEffectView(.popover) backs it.
final class StatusPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// Top-centre point the panel hangs from (screen coordinates) and the area it must stay inside.
    var anchor = NSPoint.zero
    var visibleArea = NSRect.zero
    private(set) var lastContentSize = CGSize(width: ThermikMetrics.popoverWidth, height: 420)
    private let state: StatusPanelState?
    private var userResizeInProgress = false

    init(content: AnyView, state: StatusPanelState? = nil) {
        self.state = state
        super.init(contentRect: NSRect(x: 0, y: 0, width: ThermikMetrics.popoverWidth, height: 420),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        state?.panel = self
        configurePanel()
        installContent(content, state: state)
    }

    private func configurePanel() {
        configureAppearance()
        configureBehavior()
        delegate = self
    }

    private func configureAppearance() {
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    private func configureBehavior() {
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    private func installContent(_ content: AnyView, state: StatusPanelState?) {
        let host = NSHostingView(rootView: PanelChrome(content: content, state: state))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    func resizeFromBottomRight(startFrame: NSRect, delta: NSPoint) {
        userResizeInProgress = true
        let proposed = NSSize(width: startFrame.width + delta.x, height: startFrame.height - delta.y)
        let accepted = constrainedSize(proposed, preserving: startFrame)
        let next = NSRect(x: startFrame.minX, y: startFrame.maxY - accepted.height,
                          width: accepted.width, height: accepted.height)
        setFrame(next, display: true)
    }

    func finishCustomResize() {
        userResizeInProgress = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Positions under `anchor` using the hosting view's fitting size and shows the panel.
    func show(below anchor: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        visibleArea = screen?.visibleFrame ?? .zero
        self.anchor = NSPoint(x: anchor.midX, y: anchor.minY - 6)
        placeAtAnchor(size: lastContentSize)
        makeKeyAndOrderFront(nil)
    }

    /// Applies SwiftUI's automatic size until the user chooses a size manually.
    func place(size: CGSize) {
        guard state?.customSize == nil else { return }
        placeAtAnchor(size: size)
    }

    /// Sizes the panel to `size` with its top edge on `anchor`, clamped to the visible area.
    func placeAtAnchor(size: CGSize) {
        let accepted = acceptedSizeForAnchor(size)
        lastContentSize = accepted
        synchronizeRetainedSize(accepted)
        let frame = anchoredFrame(size: accepted)
        if frame != self.frame { setFrame(frame, display: true) }
    }

    private func acceptedSizeForAnchor(_ size: CGSize) -> CGSize {
        let requested = NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height,
                               width: size.width, height: size.height)
        return constrainedSize(size, preserving: requested)
    }

    private func anchoredFrame(size: CGSize) -> NSRect {
        var frame = NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height, width: size.width, height: size.height)
        guard visibleArea.width > 0 else { return frame.integral }
        let minX = visibleArea.minX + 8
        let maxX = max(minX, visibleArea.maxX - size.width - 8)
        frame.origin.x = min(max(frame.origin.x, minX), maxX)
        frame.origin.y = max(frame.origin.y, visibleArea.minY + 4)
        return frame.integral
    }

    private func synchronizeRetainedSize(_ size: CGSize) {
        guard state?.customSize != nil else { return }
        state?.set(customSize: size)
    }
}

extension StatusPanel: NSWindowDelegate {
    private func maximumUserSize(preserving frame: NSRect) -> NSSize {
        guard visibleArea.width > 0 else { return NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude) }
        let availableWidth = min(visibleArea.width - 16, visibleArea.maxX - frame.minX - 8)
        let availableHeight = min(visibleArea.height - 16, frame.maxY - visibleArea.minY - 4)
        let width = max(ThermikMetrics.popoverMinWidth, availableWidth)
        let height = max(ThermikMetrics.popoverMinHeight, availableHeight)
        return NSSize(width: width, height: height)
    }

    private func constrainedSize(_ size: NSSize, preserving frame: NSRect) -> NSSize {
        let maximum = maximumUserSize(preserving: frame)
        let width = min(max(size.width, ThermikMetrics.popoverMinWidth), maximum.width)
        let height = min(max(size.height, ThermikMetrics.popoverMinHeight), maximum.height)
        return NSSize(width: width, height: height)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        userResizeInProgress = true
        return constrainedSize(frameSize, preserving: frame)
    }

    func windowDidResize(_ notification: Notification) {
        guard userResizeInProgress else { return }
        lastContentSize = frame.size
        state?.set(customSize: frame.size)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        userResizeInProgress = false
    }
}

struct StatusResizeHandleRepresentable: NSViewRepresentable {
    let state: StatusPanelState

    func makeNSView(context: Context) -> StatusResizeHandle {
        StatusResizeHandle(panel: state.panel)
    }

    func updateNSView(_ view: StatusResizeHandle, context: Context) {
        view.panel = state.panel
    }
}

final class StatusResizeHandle: NSView {
    fileprivate weak var panel: StatusPanel?
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero

    init(panel: StatusPanel?) {
        self.panel = panel
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        setAccessibilityElement(true)
        setAccessibilityIdentifier("popover.resizeHandle")
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Resize window"))
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        guard #available(macOS 15.0, *) else { addCursorRect(bounds, cursor: .crosshair); return }
        let cursor = NSCursor.frameResize(position: .bottomRight, directions: .all)
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        startFrame = panel?.frame ?? .zero
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel else { return }
        let current = NSEvent.mouseLocation
        let delta = NSPoint(x: current.x - startMouse.x, y: current.y - startMouse.y)
        panel.resizeFromBottomRight(startFrame: startFrame, delta: delta)
    }

    override func mouseUp(with event: NSEvent) {
        panel?.finishCustomResize()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        for offset in stride(from: CGFloat(4), through: 12, by: 4) {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: offset, y: 14))
            line.line(to: NSPoint(x: 14, y: offset))
            line.stroke()
        }
    }
}

/// Popover chrome: glass (26+), `.popover` material (14/15) or opaque (Reduce Transparency); radius 18.
struct PanelChrome: View {
    var content: AnyView
    var state: StatusPanelState? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if let state {
                if state.isOpen {
                    chrome
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { state.reportSize($0) }
                        .environment(state)
                }
            } else {
                chrome
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) { resizeHandle }
    }

    @ViewBuilder private var resizeHandle: some View {
        if let state, state.isOpen {
            StatusResizeHandleRepresentable(state: state)
                .frame(width: 14, height: 14)
        }
    }

    private var sizedContent: some View {
        content.frame(width: state?.customSize?.width ?? ThermikMetrics.popoverWidth,
                      height: state?.customSize?.height)
    }

    @ViewBuilder private var chrome: some View {
        let shape = RoundedRectangle(cornerRadius: ThermikMetrics.popoverRadius, style: .continuous)
        if reduceTransparency {
            sizedContent
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            sizedContent
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            sizedContent
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
    guard let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, r.minX > l.maxX else { return nil }
    return NSRect(x: l.maxX, y: min(l.minY, r.minY), width: r.minX - l.maxX, height: max(l.height, r.height))
}
