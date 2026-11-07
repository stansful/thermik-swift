import AppKit
import SwiftUI
import XCTest

@MainActor
final class StatusPanelTests: XCTestCase {
    func testUserResizeChangesPanelAndContentHeight() {
        let (panel, state) = makePanel()
        let size = CGSize(width: 500, height: 540)
        resize(panel, to: size)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertEqual(panel.frame.size, size)
        XCTAssertEqual(panel.lastContentSize, size)
        XCTAssertEqual(state.maxHeight, size.height)
    }

    func testAutomaticContentLayoutDoesNotUndoUserResize() {
        let (panel, _) = makePanel()
        resize(panel, to: CGSize(width: 500, height: 540))
        let resizedFrame = panel.frame
        panel.place(size: CGSize(width: 360, height: 420))
        XCTAssertEqual(panel.frame, resizedFrame)
    }

    func testChromeUsesUserSelectedSize() {
        let state = StatusPanelState()
        state.set(open: true)
        state.set(customSize: CGSize(width: 500, height: 540))
        let content = AnyView(Color.red.frame(width: 360, height: 420))
        let host = NSHostingView(rootView: PanelChrome(content: content, state: state))
        XCTAssertEqual(host.fittingSize, CGSize(width: 500, height: 540))
    }

    func testUserResizeStaysWithinMinimumSize() {
        let (panel, _) = makePanel()
        resize(panel, to: CGSize(width: 100, height: 100))
        XCTAssertEqual(panel.frame.size, CGSize(width: 320, height: 420))
    }

    func testUserResizeStaysWithinVisibleArea() {
        let (panel, _) = makePanel()
        resize(panel, to: CGSize(width: 2_000, height: 2_000))
        XCTAssertEqual(panel.frame.size, CGSize(width: 672, height: 796))
        XCTAssertEqual(panel.frame.maxX, 992)
        XCTAssertEqual(panel.frame.maxY, 800)
    }

    func testReopeningFitsRetainedSizeToSmallerScreen() {
        let (panel, state) = makePanel()
        resize(panel, to: CGSize(width: 600, height: 700))
        panel.finishCustomResize()
        panel.visibleArea = NSRect(x: 0, y: 0, width: 600, height: 600)
        panel.anchor = NSPoint(x: 300, y: 500)
        panel.placeAtAnchor(size: panel.lastContentSize)
        XCTAssertEqual(panel.frame, NSRect(x: 8, y: 4, width: 584, height: 496))
        XCTAssertEqual(state.customSize, CGSize(width: 584, height: 496))
    }

    func testBottomRightResizePreservesTopEdge() {
        let (panel, state) = makePanel()
        let start = panel.frame
        panel.resizeFromBottomRight(startFrame: start, delta: NSPoint(x: 140, y: -100))
        XCTAssertEqual(panel.frame.size, CGSize(width: 500, height: 520))
        XCTAssertEqual(panel.frame.maxY, start.maxY)
        XCTAssertEqual(state.maxHeight, 520)
    }

    func testAutomaticHeightBudgetDoesNotOverrideUserHeight() {
        let state = StatusPanelState()
        state.set(customSize: CGSize(width: 500, height: 540))
        state.set(maxHeight: 620)
        XCTAssertEqual(state.maxHeight, 540)
    }

    private func makePanel() -> (StatusPanel, StatusPanelState) {
        let state = StatusPanelState()
        let panel = StatusPanel(content: AnyView(EmptyView()), state: state)
        panel.visibleArea = NSRect(x: 0, y: 0, width: 1_000, height: 900)
        panel.anchor = NSPoint(x: 500, y: 800)
        panel.place(size: CGSize(width: 360, height: 420))
        return (panel, state)
    }

    private func resize(_ panel: StatusPanel, to proposed: CGSize) {
        let accepted = panel.delegate?.windowWillResize?(panel, to: proposed) ?? proposed
        let frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - accepted.height,
                           width: accepted.width, height: accepted.height)
        panel.setFrame(frame, display: false)
    }
}
