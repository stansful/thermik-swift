import XCTest

final class PopoverLayoutTests: XCTestCase {
    func testAutomaticLayoutKeepsMinimumSensorHeight() {
        let layout = PopoverPanelSizing.automatic(maxHeight: 200).listLayout(headerHeight: 100, footerHeight: 50)
        XCTAssertEqual(layout.maxHeight, 88)
        XCTAssertNil(layout.exactHeight)
    }

    func testCustomLayoutUsesAllRemainingHeight() {
        let layout = PopoverPanelSizing.custom(height: 540).listLayout(headerHeight: 260, footerHeight: 80)
        XCTAssertEqual(layout.maxHeight, 200)
        XCTAssertEqual(layout.exactHeight, 200)
    }

    func testCustomLayoutAllowsSensorListBelowAutomaticMinimum() {
        let layout = PopoverPanelSizing.custom(height: 420).listLayout(headerHeight: 260, footerHeight: 150)
        XCTAssertEqual(layout.maxHeight, 10)
        XCTAssertEqual(layout.exactHeight, 10)
    }
}
