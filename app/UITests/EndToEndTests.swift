import XCTest

/// Drives the whole flow on a simulator whose Photos library was seeded by the CI script:
/// scan, prepare, approve, and the system delete prompt. It runs on Codemagic, so none of it
/// needs a streamed device.
final class EndToEndTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The original four-tab interface still exists in debug builds. This test drives it directly,
    /// which proves the engine path that the memory experience builds on.
    func testScanPrepareApproveAndReplace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-EKClassicUI", "YES", "-EKMinBytes", "100000", "-EKMinPhotoBytes", "1000"]

        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            for label in ["Allow Full Access", "Allow Access to All Photos", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()

        let scan = app.buttons["scanButton"]
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "the app did not launch")
        scan.tap()
        app.tap()

        app.tabBars.buttons["Preferences"].tap()
        let prepare = app.buttons["prepareButton"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 30))
        XCTAssertFalse(prepare.isEnabled, "unassigned items must never become candidates automatically")

        let firstMode = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mode-'")).firstMatch
        XCTAssertTrue(firstMode.waitForExistence(timeout: 30))
        let mode = app.buttons[firstMode.identifier]
        if !mode.isHittable { app.swipeUp() }
        mode.tap()
        app.buttons["Protected - keep exactly"].tap()
        let bulk = app.buttons["bulkPreferenceButton"]
        waitUntilEnabled(bulk, timeout: 120, message: "the first preference was not saved")
        bulk.tap()
        app.buttons["Almost identical"].tap()
        app.buttons["Apply Almost identical"].tap()
        waitUntilEnabled(prepare, timeout: 180, message: "the unassigned item was not analyzed")
        XCTAssertTrue(prepare.label.contains("1"), "bulk assignment must not override the protected item")

        if !mode.isHittable { app.swipeUp() }
        mode.tap()
        app.buttons["Almost identical"].tap()
        let twoCandidates = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'Prepare 2' AND isEnabled == true"), object: prepare
        )
        XCTAssertEqual(XCTWaiter().wait(for: [twoCandidates], timeout: 180), .completed)
        waitUntilEnabled(prepare, timeout: 120, message: "no candidate was found; check that the sample was seeded")
        prepare.tap()

        app.tabBars.buttons["Review"].tap()
        let approve = app.buttons["approveButton"]
        waitUntilEnabled(approve, timeout: 600, message: "no candidate became ready; read the activity log")
        let twoReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'Approve 2' AND isEnabled == true"), object: approve
        )
        XCTAssertEqual(XCTWaiter().wait(for: [twoReady], timeout: 600), .completed, "both media types must pass real validation")
        approve.tap()
        app.buttons["Add verified copies and request deletion"].tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deleteButton = springboard.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete'")).firstMatch
        let done = app.staticTexts["doneBanner"]
        let deadline = Date().addingTimeInterval(600)
        while !done.exists && Date() < deadline {
            if deleteButton.exists { deleteButton.tap() }
            Thread.sleep(forTimeInterval: 1)
        }

        XCTAssertTrue(done.exists, "the replacement did not finish")
        print("EK-E2E: \(done.label)")
        XCTAssertTrue(done.label.contains("2 replaced"), done.label)
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval, message: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), message)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: timeout), .completed, message)
    }
}
