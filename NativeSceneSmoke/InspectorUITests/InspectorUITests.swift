import XCTest

@MainActor
final class InspectorUITests: XCTestCase {
    func testInspectorRelease600UserFlow() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let counters = app.staticTexts["probe.revision-policy"]
        XCTAssertTrue(counters.waitForExistence(timeout: 10))
        XCTAssertEqual(counters.label, "Revision 0 · Policy 0")
        XCTAssertTrue(app.staticTexts["accepted product via /products/:id"].exists)
        capture(app, "01-preview")

        app.buttons["Execute"].tap()
        waitForLabel(counters, "Revision 1 · Policy 1")
        capture(app, "02-executed")

        let hold = app.switches["Hold execution"]
        let holdControl = hold.switches.firstMatch.exists ? hold.switches.firstMatch : hold
        holdControl.tap()
        XCTAssertEqual(holdControl.value as? String, "1")
        app.buttons["Execute"].tap()
        waitForLabel(counters, "Revision 1 · Policy 2")
        XCTAssertFalse(app.staticTexts["applied"].exists)
        capture(app, "03-held")
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["cancelled"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Execute"].isEnabled)
        XCTAssertEqual(counters.label, "Revision 1 · Policy 2")
        capture(app, "04-cancelled")

        app.buttons["Check redacted export"].tap()
        XCTAssertTrue(app.staticTexts["PASS redacted export"].waitForExistence(timeout: 3))
        app.buttons.matching(identifier: "Timeline").firstMatch.tap()
        capture(app, "05-timeline")
        if app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        XCTAssertTrue(app.buttons["Start recording"].waitForExistence(timeout: 3))
        app.buttons["Start recording"].tap()
        XCTAssertTrue(app.buttons["Refresh progress"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Stop recording"].isHittable)
        XCTAssertTrue(app.buttons["Cancel recording"].isHittable)
        capture(app, "06-recording-controls")
        app.buttons["Refresh progress"].tap()
        XCTAssertTrue(app.buttons["Stop recording"].exists)
        app.buttons["Stop recording"].tap()
        XCTAssertTrue(app.buttons["Start recording"].waitForExistence(timeout: 3))
        app.buttons["Start recording"].tap()
        app.buttons["Cancel recording"].tap()
        XCTAssertTrue(app.buttons["Start recording"].waitForExistence(timeout: 3))
        capture(app, "07-recording-cancelled")
        app.staticTexts["transition.committed"].tap()
        XCTAssertFalse(app.staticTexts["Select an event"].exists)
        capture(app, "08-selected")
        if app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        else if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
        let search = app.searchFields["Filter events"]
        if !search.exists, app.buttons["Search"].exists { app.buttons["Search"].tap() }
        if !search.exists { app.collectionViews.firstMatch.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("zzzz-no-event-600")
        XCTAssertTrue(app.staticTexts["No matching events"].waitForExistence(timeout: 3))
        if app.frame.width >= 600 { XCTAssertTrue(app.staticTexts["Select an event"].exists) }
        else { XCTAssertFalse(app.staticTexts["Event"].exists) }
        capture(app, "09-no-matches")
        search.buttons["Clear text"].tap()
        XCTAssertTrue(app.staticTexts["transition.committed"].waitForExistence(timeout: 3))
        if app.frame.width >= 600 { XCTAssertTrue(app.staticTexts["Select an event"].exists) }
        else { XCTAssertFalse(app.staticTexts["Event"].exists) }
        capture(app, "10-filter-cleared")
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        print("INSPECTOR_UI \(name)\n\(app.debugDescription)")
    }
}
