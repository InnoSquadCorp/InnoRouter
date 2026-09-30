import XCTest

@MainActor
final class InspectorUITests: XCTestCase {
    func testInspectorMountedLocaleBidirectionalStatePreservation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "--localization-probe"]
        app.launch()
        defer { app.terminate() }
        let counters = app.staticTexts["probe.revision-policy"]
        XCTAssertTrue(counters.waitForExistence(timeout: 10))
        XCTAssertEqual(counters.label, "Revision 0 · Policy 0")
        capture(app, "locale-00-mounted-en")

        setExecutionHeld(true, in: app)
        let english = try XCTUnwrap(InspectorProbeLanguage.samples.first)
        let arabic = try XCTUnwrap(InspectorProbeLanguage.samples.last)

        for (index, language) in InspectorProbeLanguage.samples.enumerated() {
            select(language, in: app)
            XCTAssertTrue(app.navigationBars[language.deepLinkTitle].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons[language.execute].isHittable)
            if index > 0 {
                // The previous execution status must relocalize without remounting.
                XCTAssertTrue(app.staticTexts[language.cancelled].waitForExistence(timeout: 3))
            }
            XCTAssertEqual(counters.label, "Revision 0 · Policy \(index)")
            capture(app, "locale-\(language.id)-deep-link")
            app.buttons[language.execute].tap()
            waitForLabel(counters, "Revision 0 · Policy \(index + 1)")
            XCTAssertTrue(app.buttons[language.cancel].isHittable)
            if language.id == "ar" {
                for heldLanguage in [english, arabic] {
                    select(heldLanguage, in: app)
                    XCTAssertTrue(app.navigationBars[heldLanguage.deepLinkTitle].waitForExistence(timeout: 3))
                    XCTAssertFalse(app.buttons[heldLanguage.execute].isEnabled)
                    XCTAssertTrue(app.buttons[heldLanguage.cancel].isHittable)
                    XCTAssertEqual(counters.label, "Revision 0 · Policy 4")
                    capture(app, "locale-\(heldLanguage.id)-preserved-held-execution")
                }
            }
            capture(app, "locale-\(language.id)-held")
            app.buttons[language.cancel].tap()
            XCTAssertTrue(app.staticTexts[language.cancelled].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons[language.execute].isEnabled)
            XCTAssertEqual(counters.label, "Revision 0 · Policy \(index + 1)")
            capture(app, "locale-\(language.id)-execution-cancelled")
        }

        for language in [english, arabic] {
            select(language, in: app)
            XCTAssertTrue(app.navigationBars[language.deepLinkTitle].waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts[language.cancelled].exists)
            XCTAssertTrue(app.buttons[language.execute].isEnabled)
            XCTAssertEqual(app.textFields.firstMatch.value as? String, "probe://app/products/private-payload-600")
            XCTAssertEqual(counters.label, "Revision 0 · Policy 4")
            capture(app, "locale-\(language.id)-preserved-deep-link")
        }

        app.buttons.matching(identifier: "Timeline").firstMatch.tap()
        for (index, language) in InspectorProbeLanguage.samples.enumerated() {
            select(language, in: app)
            if !app.buttons[language.startRecording].exists, app.buttons["Show Sidebar"].exists {
                app.buttons["Show Sidebar"].tap()
            }
            XCTAssertTrue(app.buttons[language.startRecording].waitForExistence(timeout: 3))
            if index > 0 {
                let previousStatus = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", language.cancelled)).firstMatch
                XCTAssertTrue(previousStatus.waitForExistence(timeout: 3))
            }
            capture(app, "locale-\(language.id)-timeline")
            app.buttons[language.startRecording].tap()
            XCTAssertTrue(app.buttons[language.stopRecording].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons[language.stopRecording].isHittable)
            XCTAssertTrue(app.buttons[language.cancelRecording].isHittable)
            XCTAssertFalse(app.buttons[language.stopRecording].frame.intersects(app.buttons[language.cancelRecording].frame))
            capture(app, "locale-\(language.id)-recording")
            app.buttons[language.stopRecording].tap()
            XCTAssertTrue(app.buttons[language.startRecording].waitForExistence(timeout: 3))
            capture(app, "locale-\(language.id)-recording-stopped")
            app.buttons[language.startRecording].tap()
            XCTAssertTrue(app.buttons[language.cancelRecording].waitForExistence(timeout: 3))
            app.buttons[language.cancelRecording].tap()
            XCTAssertTrue(app.buttons[language.startRecording].waitForExistence(timeout: 3))
            let cancelledStatus = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", language.cancelled)).firstMatch
            XCTAssertTrue(cancelledStatus.waitForExistence(timeout: 3))
            capture(app, "locale-\(language.id)-recording-cancelled")
        }
        XCTAssertEqual(counters.label, "Revision 0 · Policy 4")

        app.buttons[arabic.startRecording].tap()
        XCTAssertTrue(app.buttons[arabic.stopRecording].waitForExistence(timeout: 3))
        app.staticTexts["transition.started"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["transition.started"].waitForExistence(timeout: 3))
        capture(app, "locale-ar-selected-and-recording")
        for language in [english, arabic] {
            select(language, in: app)
            // Native direction changes must not discard the Inspector's selection or recording.
            XCTAssertTrue(app.navigationBars["transition.started"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts[language.id == "ar" ? "الحدث" : "Event"].exists)
            if !app.buttons[language.stopRecording].exists {
                if app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
                else if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
            }
            XCTAssertTrue(app.buttons[language.stopRecording].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons[language.cancelRecording].isHittable)
            capture(app, "locale-\(language.id)-preserved-selection-and-recording")
        }
        app.buttons[arabic.cancelRecording].tap()
        XCTAssertTrue(app.buttons[arabic.startRecording].waitForExistence(timeout: 3))
        XCTAssertEqual(counters.label, "Revision 0 · Policy 4")
        capture(app, "locale-ar-preserved-recording-cancelled")
    }

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

        setExecutionHeld(true, in: app)
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

    func testInspectorPolicyPreparationAcknowledgesRequestedState() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "--localization-probe"]
        app.launch()
        defer { app.terminate() }
        let counters = app.staticTexts["probe.revision-policy"]
        XCTAssertTrue(counters.waitForExistence(timeout: 10))

        setExecutionHeld(false, in: app)
        setExecutionHeld(true, in: app)
        setExecutionHeld(true, in: app) // Repeating setup must not toggle it off.
        app.buttons["Execute"].tap()
        waitForLabel(counters, "Revision 0 · Policy 1")
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["cancelled"].waitForExistence(timeout: 5))
        XCTAssertEqual(counters.label, "Revision 0 · Policy 1")

        setExecutionHeld(false, in: app)
        app.buttons["Execute"].tap()
        waitForLabel(counters, "Revision 1 · Policy 2")
        capture(app, "policy-preparation-held-cancelled-resumed")
    }

    private func setExecutionHeld(_ held: Bool, in app: XCUIApplication) {
        // This configures the fixture, not the Inspector under test. Explicit
        // commands avoid depending on a nested native switch's value update.
        let command = held ? "probe.execution.hold" : "probe.execution.resume"
        let button = app.buttons[command]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
        button.tap()
        waitForLabel(app.staticTexts["probe.execution.state"], held ? "Execution held" : "Execution ready")
    }

    private func select(_ language: InspectorProbeLanguage, in app: XCUIApplication) {
        let button = app.buttons["probe.locale.\(language.id)"]
        XCTAssertTrue(button.isHittable)
        button.tap()
        waitForLabel(app.staticTexts["probe.locale.current"], "Locale \(language.id)")
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

private struct InspectorProbeLanguage: Sendable {
    let id: String
    let deepLinkTitle: String
    let execute: String
    let cancel: String
    let cancelled: String
    let startRecording: String
    let stopRecording: String
    let cancelRecording: String

    static let samples: [Self] = [
        .init(
            id: "en", deepLinkTitle: "Deep-link Inspector", execute: "Execute", cancel: "Cancel", cancelled: "cancelled",
            startRecording: "Start recording", stopRecording: "Stop recording", cancelRecording: "Cancel recording"
        ),
        .init(
            id: "ko", deepLinkTitle: "딥 링크 인스펙터", execute: "실행", cancel: "취소", cancelled: "취소됨",
            startRecording: "기록 시작", stopRecording: "기록 중지", cancelRecording: "기록 취소"
        ),
        .init(
            id: "de", deepLinkTitle: "Deep-Link-Inspektor", execute: "Ausführen", cancel: "Abbrechen", cancelled: "abgebrochen",
            startRecording: "Aufzeichnung starten", stopRecording: "Aufzeichnung stoppen", cancelRecording: "Aufzeichnung abbrechen"
        ),
        .init(
            id: "ar", deepLinkTitle: "فاحص الروابط العميقة", execute: "تنفيذ", cancel: "إلغاء", cancelled: "ملغى",
            startRecording: "بدء التسجيل", stopRecording: "إيقاف التسجيل", cancelRecording: "إلغاء التسجيل"
        ),
    ]
}
