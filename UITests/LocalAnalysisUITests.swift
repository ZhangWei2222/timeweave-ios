import XCTest

// Opt-in scheme; start the local server first. Use an isolated simulator.
final class LocalAnalysisUITests: XCTestCase {
    @MainActor
    func testUnavailableServerShowsRetry() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["统计"].tap()
        app.buttons["AI 分析近 7 天"].tap()
        app.buttons["submitAnalysis"].tap()
        XCTAssertTrue(app.staticTexts["暂时无法分析"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["重试"].exists)
        XCTAssertTrue(app.buttons["submitAnalysis"].isEnabled)
    }
    @MainActor
    func testSnapshotAnalysisReachesServerAndDisplaysAnswer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["统计"].tap()
        app.buttons["AI 分析近 7 天"].tap()
        XCTAssertTrue(app.buttons["submitAnalysis"].waitForExistence(timeout: 5))
        app.buttons["submitAnalysis"].tap()
        XCTAssertTrue(app.staticTexts["分析结果"].waitForExistence(timeout: 40), app.debugDescription)
        XCTAssertFalse(app.staticTexts["暂时无法分析"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["记录"].tap()
        app.buttons["添加时间"].tap()
        app.buttons["saveEntry"].tap()
        app.tabBars.buttons["统计"].tap()
        app.buttons["AI 分析近 7 天"].tap()
        app.buttons["submitAnalysis"].tap()
        XCTAssertTrue(app.staticTexts["分析结果"].waitForExistence(timeout: 40), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "60")).firstMatch.exists, app.debugDescription)
        let recorded = XCTAttachment(screenshot: app.screenshot())
        recorded.lifetime = .keepAlways
        add(recorded)
    }
}
