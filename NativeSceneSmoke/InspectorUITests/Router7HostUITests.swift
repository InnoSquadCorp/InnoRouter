import XCTest

/// Native interactions against the macro-first Router 7 sample, not an app pilot.
@MainActor
final class Router7HostUITests: XCTestCase {
    func testNestedModalTypedResultsAndReentry() {
        let app = launch()
        tap("host.open-outer", app)
        label("host.modal-title", "Outer modal", app)
        tap("host.open-inner", app)
        label("host.modal-title", "Inner modal", app)
        tap("host.finish", app)
        label("host.modal-title", "Outer modal", app)
        label("host.inner-result", "Inner value true", app)
        tap("host.finish", app)
        label("host.outer-result", "Outer value true", app)
        tap("host.open-outer", app)
        label("host.modal-title", "Outer modal", app)
        tap("host.close", app)
        label("host.outer-result", "Outer dismissed", app)
        capture(app, "nested-completed-and-reentered")
    }

    func testNativeAlertAndDialogInsideRecursiveChild() {
        let app = launch()
        tap("host.open-outer", app)
        tap("host.open-inner", app)
        tap("inner.alert", app)
        XCTAssertTrue(app.alerts["Router alert"].waitForExistence(timeout: 5))
        capture(app, "recursive-alert")
        tap("Accept alert", app)
        label("inner.transient-result", "Alert value true", app)
        tap("inner.dialog", app)
        XCTAssertTrue(app.buttons["Accept dialog"].waitForExistence(timeout: 5))
        capture(app, "recursive-dialog")
        tap("Accept dialog", app)
        label("inner.transient-result", "Dialog value true", app)
        tap("inner.alert", app)
        tap("Cancel alert", app)
        label("inner.transient-result", "Alert value false", app)
        tap("host.close", app)
        label("host.inner-result", "Inner dismissed", app)
        tap("host.close", app)
        label("host.outer-result", "Outer dismissed", app)
    }

    func testNativeRootAlert() {
        let app = launch()
        tap("host.alert", app)
        XCTAssertTrue(app.alerts["Router alert"].waitForExistence(timeout: 5))
        capture(app, "root-alert")
        tap("Accept alert", app)
        label("host.transient-result", "Alert value true", app)
    }

    func testNativeRootDialog() {
        let app = launch()
        tap("host.dialog", app)
        XCTAssertTrue(app.buttons["Accept dialog"].waitForExistence(timeout: 5))
        capture(app, "root-dialog")
        tap("Accept dialog", app)
        label("host.transient-result", "Dialog value true", app)
    }

    func testClosedModalCallbackCannotDismissReenteredModal() {
        let app = launch()
        tap("host.open-outer", app)
        tap("host.capture-modal", app)
        label("host.modal-status", "Modal captured", app)
        tap("host.close", app)
        label("host.outer-result", "Outer dismissed", app)
        tap("host.open-outer", app)
        tap("host.old-modal", app)
        label("host.modal-status", "Old callback: rejected; unchanged true", app)
        label("host.modal-title", "Outer modal", app)
        capture(app, "stale-modal-callback-rejected")
        tap("host.finish", app)
        label("host.outer-result", "Outer value true", app)
    }

    func testCancelWaiterAndReenter() {
        let app = launch()
        tap("host.open-outer", app)
        tap("host.cancel-waiter", app)
        label("host.outer-result", "Outer cancelled", app)
        tap("host.open-outer", app)
        label("host.modal-title", "Outer modal", app)
        tap("host.finish", app)
        label("host.outer-result", "Outer value true", app)
        capture(app, "cancelled-and-reentered")
    }

    func testNativeTabsSplitReplacementAndStaleScope() {
        let app = launch()
        tap("Settings", app)
        label("host.root", "Settings root", app)
        tap("host.open-detail", app)
        label("host.detail", "Detail Settings root", app)
        tap("Home", app)
        label("host.root", "Home root", app)
        tap("Settings", app)
        label("host.detail", "Detail Settings root", app)
        tap("host.back-root", app)
        tap("host.capture-scope", app)
        label("host.status", "Scope captured", app)
        tap("host.split", app)
        label("host.status", "Replace split: applied", app)
        label("host.root", "Split detail root", app)
        XCTAssertTrue(app.staticTexts["host.sidebar"].waitForExistence(timeout: 5))
        tap("host.old-scope", app)
        label("host.status", "Old scope: rejected; unchanged true", app)
        tap("host.open-detail", app)
        label("host.detail", "Detail Split detail root", app)
        tap("host.sidebar-detail", app)
        XCTAssertTrue(app.staticTexts.matching(identifier: "host.detail").matching(NSPredicate(format: "label == %@", "Detail Sidebar")).firstMatch.waitForExistence(timeout: 5))
        capture(app, "split-independent-stacks")
        tap("host.tabs", app)
        label("host.root", "Home root", app)
        capture(app, "tabs-reentered")
    }

    func testSnapshotRestoresSelectionAndPathsAfterRelaunch() {
        let app = launch()
        tap("host.open-detail", app)
        label("host.detail", "Detail Home root", app)
        tap("Settings", app)
        tap("host.open-detail", app)
        label("host.detail", "Detail Settings root", app)
        tap("host.save", app)
        label("host.status", "Snapshot saved", app)
        capture(app, "snapshot-saved")
        app.terminate()
        app.launch()
        label("host.root", "Home root", app)
        tap("host.restore", app)
        label("host.status", "Snapshot restored: applied", app)
        label("host.detail", "Detail Settings root", app)
        tap("Home", app)
        label("host.detail", "Detail Home root", app)
        capture(app, "snapshot-restored-after-process-relaunch")
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--router7-host-probe", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        label("host.status", "Ready", app)
        label("host.root", "Home root", app)
        capture(app, "initial-tabs")
        return app
    }

    private func tap(_ identifier: String, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // Native nested sheets retain covered ancestors in the hierarchy.
        // Select the current touch target, never the first duplicate identifier.
        let candidates = app.buttons.matching(identifier: identifier)
        let predicate = NSPredicate { _, _ in
            MainActor.assumeIsolated { candidates.allElementsBoundByIndex.contains { $0.isHittable } }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 8), .completed, "Button \(identifier) not hittable", file: file, line: line)
        capture(app, "before-\(identifier)")
        guard let button = candidates.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("No visible button \(identifier)", file: file, line: line)
            return
        }
        button.tap()
        capture(app, "after-\(identifier)")
    }

    private func label(_ identifier: String, _ expected: String, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let candidates = app.staticTexts.matching(identifier: identifier)
            .matching(NSPredicate(format: "label == %@", expected))
        let predicate = NSPredicate { _, _ in
            MainActor.assumeIsolated { candidates.allElementsBoundByIndex.contains { $0.isHittable } }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 8), .completed, "Expected visible \(identifier): \(expected)", file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        print("ROUTER7_UI_CAPTURE \(name)\n\(app.debugDescription)")
    }
}
