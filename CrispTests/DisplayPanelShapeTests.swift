import XCTest

/// The shape rule that keeps entries with no screen behind them out of the active count.
final class DisplayPanelShapeTests: XCTestCase {
    func testPlaceholderAndStubHaveNoPanel() {
        XCTAssertFalse(DisplayPanelShape.hasPanel(vendor: 0x756E6B6E, model: 0x76697274))
        XCTAssertFalse(DisplayPanelShape.hasPanel(vendor: 0, model: 0))
    }

    func testRealPanelsCount() {
        XCTAssertTrue(DisplayPanelShape.hasPanel(vendor: 0x0610, model: 0xA049))
        XCTAssertTrue(DisplayPanelShape.hasPanel(vendor: 0x10AC, model: 0xA0C4))
        XCTAssertTrue(DisplayPanelShape.hasPanel(vendor: 0x05E3, model: 0x2730))
    }

    /// The aigo portable monitor from #238 reports product code 0.
    func testModelZeroWithRealVendorCounts() {
        XCTAssertTrue(DisplayPanelShape.hasPanel(vendor: 0x6318, model: 0))
    }
}
