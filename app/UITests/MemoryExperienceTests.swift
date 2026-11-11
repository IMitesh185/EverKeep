import XCTest

/// The default interface, end to end, on the same seeded Photos library as `EndToEndTests`:
/// scan, turn the dial, look at the real media, prepare, preserve, and the system delete prompt.
final class MemoryExperienceTests: XCTestCase {
    private let order = ["Photos", "Live Photos", "Videos", "Screenshots"]

    override func setUp() {
        continueAfterFailure = false
    }

    func testDialReviewPrepareAndPreserve() {
        let app = XCUIApplication()
        app.launchArguments = ["-EKMinBytes", "100000", "-EKMinPhotoBytes", "1000"]

        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            for label in ["Allow Full Access", "Allow Access to All Photos", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()

        let scan = app.buttons["welcomeScanButton"]
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "the welcome screen did not appear")
        scan.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).tap()

        let dial = app.descendants(matching: .any)["dial"]
        XCTAssertTrue(dial.waitForExistence(timeout: 120), "the scan did not reach the main screen")
        XCTAssertEqual(dial.value as? String, "Photos", "the dial starts on Photos")
        XCTAssertEqual(app.tabBars.count, 0, "there is no bottom navigation")
        XCTAssertTrue(app.descendants(matching: .any)["usedValue"].exists, "storage consumed is shown")
        XCTAssertTrue(app.descendants(matching: .any)["savingsValue"].exists, "potential savings are shown")

        preserveWhatIsShown(in: app)

        turnDial(in: app, to: "Videos")
        preserveWhatIsShown(in: app)
    }

    // MARK: Steps

    /// Opens the review of the selected category, looks closer at one item, and takes it through both approvals.
    private func preserveWhatIsShown(in app: XCUIApplication) {
        let review = app.buttons["reviewButton"]
        XCTAssertTrue(review.waitForExistence(timeout: 30), "the main screen has no review action")
        wait(for: review, toSatisfy: "isEnabled == true", timeout: 300, "the library was never measured")
        review.tap()

        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tile-'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "the review must show the actual media")
        tile.tap()
        let close = app.buttons["sheetClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 30), "tapping an item opens a closer look")
        close.tap()
        wait(for: close, toSatisfy: "exists == false", timeout: 15, "the closer look did not close")

        // Items Everkeep is unsure about start left out, so the person includes one on purpose.
        let primary = app.buttons["reviewPrimaryButton"]
        XCTAssertTrue(primary.waitForExistence(timeout: 30))
        if !primary.isEnabled {
            let toggle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tileToggle-'")).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            toggle.tap()
        }
        wait(for: primary, toSatisfy: "label BEGINSWITH 'Prepare' AND isEnabled == true", timeout: 30, "nothing could be prepared")
        primary.tap()

        wait(for: primary, toSatisfy: "label BEGINSWITH 'Preserve' AND isEnabled == true", timeout: 600,
             "no copy passed the checks; read the activity log")
        primary.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deleteButton = springboard.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete'")).firstMatch
        let done = app.staticTexts["doneTitle"]
        let deadline = Date().addingTimeInterval(600)
        while !done.exists && Date() < deadline {
            if deleteButton.exists { deleteButton.tap() }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(done.exists, "the replacement did not finish")
        print("EK-E2E: \(done.label)")
        XCTAssertTrue(done.label.contains("smaller"), "the originals were not replaced: \(done.label)")

        app.buttons["doneButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["dial"].waitForExistence(timeout: 30), "Done must return to the dial")
    }

    /// Turns the dial with a drag along its upper edge, checking where it came to rest.
    private func turnDial(in app: XCUIApplication, to title: String) {
        let dial = app.descendants(matching: .any)["dial"]
        let target = order.firstIndex(of: title) ?? 0
        for _ in 0..<6 {
            let current = order.firstIndex(of: dial.value as? String ?? "") ?? 0
            if current == target { break }
            let forward = target > current
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.64 : 0.36, dy: 0.86))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.36 : 0.64, dy: 0.86))
            from.press(forDuration: 0.05, thenDragTo: to)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(dial.value as? String, title, "the dial did not come to rest on \(title)")
    }

    private func wait(for element: XCUIElement, toSatisfy format: String, timeout: TimeInterval, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message)
    }
}
