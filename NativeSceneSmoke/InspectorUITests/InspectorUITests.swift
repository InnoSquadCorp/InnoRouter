import XCTest

@MainActor
final class InspectorUITests: XCTestCase {
    // MARK: - Localization scenarios

    // Each scenario launches its own probe, so one failure costs one scenario
    // instead of every localization check that followed it in one long flow.

    /// Deep-link execution status relocalizes in place, and a held execution
    /// survives locale and layout-direction changes.
    func testInspectorLocaleRelocalizesHeldExecutionWithoutRemounting() throws {
        let (app, counters) = launchProbe(localizationProbe: true)
        defer { app.terminate() }
        capture(app, "locale-00-mounted-en")

        setExecutionHeld(true, in: app)
        let english = try XCTUnwrap(InspectorProbeLanguage.samples.first)
        let arabic = try XCTUnwrap(InspectorProbeLanguage.samples.last)

        for (index, language) in InspectorProbeLanguage.samples.enumerated() {
            select(language, in: app)
            waitForExistence(app.navigationBars[language.deepLinkTitle])
            waitForHittable(app.buttons[language.execute])
            if index > 0 {
                // The previous execution status must relocalize without remounting.
                waitForExistence(app.staticTexts[language.cancelled])
            }
            waitForLabel(counters, "Revision 0 · Policy \(index)")
            capture(app, "locale-\(language.id)-deep-link")
            app.buttons[language.execute].tap()
            waitForLabel(counters, "Revision 0 · Policy \(index + 1)")
            waitForHittable(app.buttons[language.cancel])
            if language.id == arabic.id {
                for heldLanguage in [english, arabic] {
                    select(heldLanguage, in: app)
                    waitForExistence(app.navigationBars[heldLanguage.deepLinkTitle])
                    waitForEnabled(app.buttons[heldLanguage.execute], false)
                    waitForHittable(app.buttons[heldLanguage.cancel])
                    waitForLabel(counters, "Revision 0 · Policy 4")
                    capture(app, "locale-\(heldLanguage.id)-preserved-held-execution")
                }
            }
            capture(app, "locale-\(language.id)-held")
            app.buttons[language.cancel].tap()
            waitForExistence(app.staticTexts[language.cancelled], timeout: 5)
            waitForEnabled(app.buttons[language.execute], true)
            waitForLabel(counters, "Revision 0 · Policy \(index + 1)")
            capture(app, "locale-\(language.id)-execution-cancelled")
        }

        for language in [english, arabic] {
            select(language, in: app)
            waitForExistence(app.navigationBars[language.deepLinkTitle])
            waitForExistence(app.staticTexts[language.cancelled])
            waitForEnabled(app.buttons[language.execute], true)
            waitForValue(app.textFields.firstMatch, "probe://app/products/private-payload-600")
            waitForLabel(counters, "Revision 0 · Policy 4")
            capture(app, "locale-\(language.id)-preserved-deep-link")
        }
    }

    /// Timeline recording controls relocalize in place, and the previous
    /// recording status follows each new locale.
    func testInspectorLocaleRelocalizesRecordingControlsWithoutRemounting() throws {
        let (app, counters) = launchProbe(localizationProbe: true)
        defer { app.terminate() }

        app.buttons.matching(identifier: "Timeline").firstMatch.tap()
        for (index, language) in InspectorProbeLanguage.samples.enumerated() {
            select(language, in: app)
            revealRecordingControls(language, in: app)
            if index > 0 {
                waitForExistence(status(containing: language.cancelled, in: app))
            }
            capture(app, "locale-\(language.id)-timeline")
            app.buttons[language.startRecording].tap()
            waitForHittable(app.buttons[language.stopRecording])
            waitForHittable(app.buttons[language.cancelRecording])
            XCTAssertFalse(app.buttons[language.stopRecording].frame.intersects(app.buttons[language.cancelRecording].frame))
            capture(app, "locale-\(language.id)-recording")
            app.buttons[language.stopRecording].tap()
            waitForExistence(app.buttons[language.startRecording])
            capture(app, "locale-\(language.id)-recording-stopped")
            app.buttons[language.startRecording].tap()
            waitForExistence(app.buttons[language.cancelRecording])
            app.buttons[language.cancelRecording].tap()
            waitForExistence(app.buttons[language.startRecording])
            waitForExistence(status(containing: language.cancelled, in: app))
            capture(app, "locale-\(language.id)-recording-cancelled")
        }
        // Recording never executes a deep link, so no policy runs.
        waitForLabel(counters, "Revision 0 · Policy 0")
    }

    /// A selected event and an in-progress recording survive layout-direction
    /// changes between right-to-left and left-to-right locales.
    func testInspectorDirectionChangePreservesSelectionAndRecording() throws {
        let (app, counters) = launchProbe(localizationProbe: true)
        defer { app.terminate() }
        let english = try XCTUnwrap(InspectorProbeLanguage.samples.first)
        let arabic = try XCTUnwrap(InspectorProbeLanguage.samples.last)

        // One held, then cancelled execution records the event selected below.
        setExecutionHeld(true, in: app)
        app.buttons[english.execute].tap()
        waitForLabel(counters, "Revision 0 · Policy 1")
        waitForHittable(app.buttons[english.cancel])
        app.buttons[english.cancel].tap()
        waitForExistence(app.staticTexts[english.cancelled], timeout: 5)

        select(arabic, in: app)
        app.buttons.matching(identifier: "Timeline").firstMatch.tap()
        revealRecordingControls(arabic, in: app)
        app.buttons[arabic.startRecording].tap()
        waitForExistence(app.buttons[arabic.stopRecording])
        let startedEvent = app.staticTexts["transition.started"].firstMatch
        waitForExistence(startedEvent)
        startedEvent.tap()
        waitForExistence(app.navigationBars["transition.started"])
        capture(app, "locale-ar-selected-and-recording")
        for language in [english, arabic] {
            select(language, in: app)
            // Native direction changes must not discard the Inspector's selection or recording.
            waitForExistence(app.navigationBars["transition.started"])
            waitForExistence(app.staticTexts[language.id == "ar" ? "الحدث" : "Event"])
            if !app.buttons[language.stopRecording].exists {
                if app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
                else if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
            }
            waitForExistence(app.buttons[language.stopRecording])
            waitForHittable(app.buttons[language.cancelRecording])
            capture(app, "locale-\(language.id)-preserved-selection-and-recording")
        }
        app.buttons[arabic.cancelRecording].tap()
        waitForExistence(app.buttons[arabic.startRecording])
        waitForLabel(counters, "Revision 0 · Policy 1")
        capture(app, "locale-ar-preserved-recording-cancelled")
    }

    // MARK: - Release and preparation flows

    func testInspectorRelease600UserFlow() throws {
        let (app, counters) = launchProbe(localizationProbe: false)
        defer { app.terminate() }
        waitForExistence(app.staticTexts["accepted product via /products/:id"])
        capture(app, "01-preview")

        app.buttons["Execute"].tap()
        waitForLabel(counters, "Revision 1 · Policy 1")
        capture(app, "02-executed")

        setExecutionHeld(true, in: app)
        app.buttons["Execute"].tap()
        waitForLabel(counters, "Revision 1 · Policy 2")
        XCTAssertFalse(app.staticTexts["applied"].exists)
        capture(app, "03-held")
        waitForHittable(app.buttons["Cancel"])
        app.buttons["Cancel"].tap()
        waitForExistence(app.staticTexts["cancelled"], timeout: 5)
        waitForEnabled(app.buttons["Execute"], true)
        waitForLabel(counters, "Revision 1 · Policy 2")
        capture(app, "04-cancelled")

        app.buttons["Check redacted export"].tap()
        waitForExistence(app.staticTexts["PASS redacted export"])
        app.buttons.matching(identifier: "Timeline").firstMatch.tap()
        capture(app, "05-timeline")
        if app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        waitForExistence(app.buttons["Start recording"])
        app.buttons["Start recording"].tap()
        waitForExistence(app.buttons["Refresh progress"])
        waitForHittable(app.buttons["Stop recording"])
        waitForHittable(app.buttons["Cancel recording"])
        capture(app, "06-recording-controls")
        app.buttons["Refresh progress"].tap()
        waitForExistence(app.buttons["Stop recording"])
        app.buttons["Stop recording"].tap()
        waitForExistence(app.buttons["Start recording"])
        app.buttons["Start recording"].tap()
        app.buttons["Cancel recording"].tap()
        waitForExistence(app.buttons["Start recording"])
        capture(app, "07-recording-cancelled")
        app.staticTexts["transition.committed"].tap()
        XCTAssertFalse(app.staticTexts["Select an event"].exists)
        capture(app, "08-selected")
        if app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        else if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
        let search = app.searchFields["Filter events"]
        if !search.exists, app.buttons["Search"].exists { app.buttons["Search"].tap() }
        if !search.exists { app.collectionViews.firstMatch.swipeDown() }
        waitForExistence(search)
        search.tap()
        search.typeText("zzzz-no-event-600")
        waitForExistence(app.staticTexts["No matching events"])
        if app.frame.width >= 600 { XCTAssertTrue(app.staticTexts["Select an event"].exists) }
        else { XCTAssertFalse(app.staticTexts["Event"].exists) }
        capture(app, "09-no-matches")
        search.buttons["Clear text"].tap()
        waitForExistence(app.staticTexts["transition.committed"])
        if app.frame.width >= 600 { XCTAssertTrue(app.staticTexts["Select an event"].exists) }
        else { XCTAssertFalse(app.staticTexts["Event"].exists) }
        capture(app, "10-filter-cleared")
    }

    func testInspectorPolicyPreparationAcknowledgesRequestedState() {
        let (app, counters) = launchProbe(localizationProbe: true)
        defer { app.terminate() }

        setExecutionHeld(false, in: app)
        setExecutionHeld(true, in: app)
        setExecutionHeld(true, in: app) // Repeating setup must not toggle it off.
        app.buttons["Execute"].tap()
        waitForLabel(counters, "Revision 0 · Policy 1")
        waitForHittable(app.buttons["Cancel"])
        app.buttons["Cancel"].tap()
        waitForExistence(app.staticTexts["cancelled"], timeout: 5)
        waitForLabel(counters, "Revision 0 · Policy 1")

        setExecutionHeld(false, in: app)
        app.buttons["Execute"].tap()
        waitForLabel(counters, "Revision 1 · Policy 2")
        capture(app, "policy-preparation-held-cancelled-resumed")
    }

    // MARK: - Probe fixture

    private func launchProbe(
        localizationProbe: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (XCUIApplication, XCUIElement) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            + (localizationProbe ? ["--localization-probe"] : [])
        app.launch()
        let counters = app.staticTexts["probe.revision-policy"]
        waitForExistence(counters, timeout: 10, file: file, line: line)
        XCTAssertEqual(counters.label, "Revision 0 · Policy 0", file: file, line: line)
        return (app, counters)
    }

    private func setExecutionHeld(
        _ held: Bool,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // This configures the fixture, not the Inspector under test. Explicit
        // commands avoid depending on a nested native switch's value update.
        let command = held ? "probe.execution.hold" : "probe.execution.resume"
        let button = app.buttons[command]
        waitForExistence(button, timeout: 5, file: file, line: line)
        waitForHittable(button, file: file, line: line)
        button.tap()
        waitForLabel(
            app.staticTexts["probe.execution.state"],
            held ? "Execution held" : "Execution ready",
            file: file,
            line: line
        )
    }

    private func select(
        _ language: InspectorProbeLanguage,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = app.buttons["probe.locale.\(language.id)"]
        waitForHittable(button, file: file, line: line)
        button.tap()
        waitForLabel(app.staticTexts["probe.locale.current"], "Locale \(language.id)", file: file, line: line)
    }

    private func revealRecordingControls(
        _ language: InspectorProbeLanguage,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !app.buttons[language.startRecording].exists, app.buttons["Show Sidebar"].exists {
            app.buttons["Show Sidebar"].tap()
        }
        waitForExistence(app.buttons[language.startRecording], file: file, line: line)
    }

    private func status(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    // MARK: - Waiting

    // Every state change is awaited through a predicate rather than read once,
    // and a timeout names the element, the awaited state, and what was
    // observed, reported at the calling line.

    private func waitForExistence(
        _ element: XCUIElement,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !element.waitForExistence(timeout: timeout) {
            XCTFail("Timed out after \(timeout)s waiting for \(element) to exist", file: file, line: line)
        }
    }

    private func waitForLabel(
        _ element: XCUIElement,
        _ label: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitFor(element, NSPredicate(format: "label == %@", label), "to have label \"\(label)\"", timeout, file, line)
    }

    private func waitForValue(
        _ element: XCUIElement,
        _ value: String,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitFor(element, NSPredicate(format: "value == %@", value), "to have value \"\(value)\"", timeout, file, line)
    }

    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitFor(element, NSPredicate(format: "hittable == true"), "to be hittable", timeout, file, line)
    }

    private func waitForEnabled(
        _ element: XCUIElement,
        _ enabled: Bool,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let goal = enabled ? "to be enabled" : "to be disabled"
        waitFor(element, NSPredicate(format: "enabled == %@", NSNumber(value: enabled)), goal, timeout, file, line)
    }

    private func waitFor(
        _ element: XCUIElement,
        _ predicate: NSPredicate,
        _ goal: String,
        _ timeout: TimeInterval,
        _ file: StaticString,
        _ line: UInt
    ) {
        // Check once before polling. A predicate expectation first evaluates
        // about a second after it starts, so the common, already satisfied
        // case would otherwise spend that second, as a one-time read never
        // did. The full timeout then applies to the wait, and `exists` is
        // evaluated first so an attribute is read only from a resolvable
        // element.
        if element.exists, predicate.evaluate(with: element) { return }
        let satisfied = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "exists == true"),
            predicate,
        ])
        let expectation = XCTNSPredicateExpectation(predicate: satisfied, object: element)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) != .completed else { return }
        let observed = element.exists ? "label \"\(element.label)\"" : "no matching element"
        XCTFail("Timed out after \(timeout)s waiting for \(element) \(goal); observed \(observed)", file: file, line: line)
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
