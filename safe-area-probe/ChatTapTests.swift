import XCTest

final class ChatTapTests: XCTestCase {
    @MainActor
    func testTapOutsideEditorDismissesKeyboard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let web = app.webViews.firstMatch
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20))

        for cycle in 1...2 {
            XCTContext.runActivity(named: "Keyboard cycle \(cycle)") { _ in
                XCTAssertTrue(web.staticTexts["Ready \(cycle)"].waitForExistence(timeout: 15))
                web.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.975)).tap()
                XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
                let x: CGFloat = cycle == 1 ? 0.15 : 0.92
                web.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.37)).tap()
                XCTAssertTrue(keyboard.waitForNonExistence(timeout: 10))
            }
        }

        XCTAssertTrue(web.staticTexts["Measurements ready"].waitForExistence(timeout: 10))
    }
}
