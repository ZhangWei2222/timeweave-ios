import XCTest

// Opt-in scheme; start the local server first. Use an isolated simulator.
final class LocalAnalysisUITests: XCTestCase {
    @MainActor
    func testTimerStartStopOpensConfirmationAndSaves() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments.append("--reset-ledger-for-ui-testing")
        app.launch()

        XCTAssertTrue(app.buttons["startTimer"].waitForExistence(timeout: 5))
        let initialEntryCount = app.buttons.matching(identifier: "timeEntry").count
        app.buttons["startTimer"].tap()
        XCTAssertTrue(app.buttons["stopTimer"].waitForExistence(timeout: 5))
        app.buttons["stopTimer"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["entryEditorOverlay"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertTrue(app.buttons["saveEntry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["分类，工作"].isHittable)
        XCTAssertTrue(app.textFields["entryNote"].isHittable)
        assertEditorContentIsFullyVisible(in: app)
        let singleScreenLayout = XCTAttachment(screenshot: app.screenshot())
        singleScreenLayout.name = "EntryEditor 单屏布局"
        singleScreenLayout.lifetime = .keepAlways
        add(singleScreenLayout)
        selectWorkCategory(in: app)
        app.buttons["saveEntry"].tap()

        XCTAssertTrue(app.buttons["startTimer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "timeEntry").count, initialEntryCount + 1)
        XCTAssertTrue(app.staticTexts["工作"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testManyCategoriesKeepEditorOnOneScreen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--reset-ledger-for-ui-testing", "--seed-many-categories-for-ui-testing"]
        app.launch()

        XCTAssertTrue(app.buttons["startTimer"].waitForExistence(timeout: 5))
        app.buttons["startTimer"].tap()
        XCTAssertTrue(app.buttons["stopTimer"].waitForExistence(timeout: 5))
        app.buttons["stopTimer"].tap()

        XCTAssertTrue(app.buttons["更多分类"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["更多分类"].isHittable)
        XCTAssertTrue(app.textFields["entryNote"].isHittable)
        XCTAssertTrue(app.buttons["saveEntry"].isHittable)
        assertEditorContentIsFullyVisible(in: app)
    }
    @MainActor
    func testUnavailableServerShowsRetry() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--reset-ledger-for-ui-testing")
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
        app.launchArguments.append("--reset-ledger-for-ui-testing")
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
        let initialEntryCount = app.buttons.matching(identifier: "timeEntry").count
        app.buttons["startTimer"].tap()
        XCTAssertTrue(app.buttons["stopTimer"].waitForExistence(timeout: 5))
        app.buttons["stopTimer"].tap()
        XCTAssertTrue(app.buttons["saveEntry"].waitForExistence(timeout: 5))
        try setStartTimeAtLeastOneMinuteEarlier(in: app)
        selectWorkCategory(in: app)
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["entryEditorOverlay"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "timeEntry").count, initialEntryCount + 1)
        let savedDuration = app.staticTexts["entryDuration"]
        XCTAssertTrue(savedDuration.waitForExistence(timeout: 5))
        XCTAssertNotEqual(savedDuration.label, "不足 1 分钟")
        app.tabBars.buttons["统计"].tap()
        app.buttons["AI 分析近 7 天"].tap()
        app.buttons["submitAnalysis"].tap()
        XCTAssertTrue(app.staticTexts["分析结果"].waitForExistence(timeout: 40), app.debugDescription)
        let recorded = XCTAttachment(screenshot: app.screenshot())
        recorded.lifetime = .keepAlways
        add(recorded)
    }

    @MainActor
    private func selectWorkCategory(in app: XCUIApplication) {
        let work = app.buttons["分类，工作"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.tap()
    }

    @MainActor
    private func assertEditorContentIsFullyVisible(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let overlay = app.descendants(matching: .any)["entryEditorOverlay"]
        let category = app.buttons["分类，工作"]
        let note = app.textFields["entryNote"]
        let save = app.buttons["saveEntry"]

        XCTAssertTrue(overlay.frame.contains(category.frame), "分类被面板裁切：\(category.frame)", file: file, line: line)
        XCTAssertTrue(overlay.frame.contains(note.frame), "备注被面板裁切：\(note.frame)", file: file, line: line)
        XCTAssertTrue(overlay.frame.contains(save.frame), "确定按钮被面板裁切：\(save.frame)", file: file, line: line)
        XCTAssertLessThanOrEqual(category.frame.maxY, note.frame.minY, "分类与备注发生遮挡", file: file, line: line)
        XCTAssertLessThanOrEqual(note.frame.maxY, save.frame.minY, "备注与确定按钮发生遮挡", file: file, line: line)
    }

    @MainActor
    private func setStartTimeAtLeastOneMinuteEarlier(in app: XCUIApplication) throws {
        let wheels = app.datePickers["startTimePicker"].pickerWheels
        let hourWheel = wheels.element(boundBy: 0)
        XCTAssertTrue(hourWheel.waitForExistence(timeout: 5))
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        if hour > 0 {
            hourWheel.adjust(toPickerWheelValue: String(hour - 1))
            let minuteWheel = wheels.element(boundBy: 1)
            XCTAssertTrue(minuteWheel.exists)
            minuteWheel.adjust(toPickerWheelValue: "00")
        } else if minute > 0 {
            let minuteWheel = wheels.element(boundBy: 1)
            XCTAssertTrue(minuteWheel.exists)
            minuteWheel.adjust(toPickerWheelValue: "00")
        } else {
            throw XCTSkip("午夜第 1 分钟内无法只靠同日时间滚轮构造已发生的一分钟记录。")
        }
    }
}
