import XCTest

/// Drives the whole flow on a simulator whose Photos library was seeded by the CI script:
/// scan, prepare, approve, and the system delete prompt. It runs on Codemagic, so none of it
/// needs a streamed device.
final class EndToEndTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testScanPrepareApproveAndReplace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-EKMinBytes", "100000"]

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

        app.tabBars.buttons["Candidates"].tap()
        let prepare = app.buttons["prepareButton"]
        waitUntilEnabled(prepare, timeout: 120, message: "no candidate was found; check that the sample was seeded")
        prepare.tap()

        app.tabBars.buttons["Review"].tap()
        let approve = app.buttons["approveButton"]
        waitUntilEnabled(approve, timeout: 600, message: "no candidate became ready; read the activity log")
        approve.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deleteButton = springboard.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete'")).firstMatch
        let done = app.staticTexts["doneBanner"]
        let deadline = Date().addingTimeInterval(180)
        while !done.exists && Date() < deadline {
            if deleteButton.exists { deleteButton.tap() }
            Thread.sleep(forTimeInterval: 1)
        }

        XCTAssertTrue(done.exists, "the replacement did not finish")
        print("EK-E2E: \(done.label)")
        XCTAssertTrue(done.label.contains("1 replaced"), done.label)
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval, message: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), message)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: timeout), .completed, message)
    }
}
