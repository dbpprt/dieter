import XCTest

final class ComposeSpikeUITests: XCTestCase {
    private var application: XCUIApplication?

    override func tearDown() {
        if let app = application {
            if testRun?.hasSucceeded == false {
                let hierarchy = XCTAttachment(string: String(app.debugDescription.prefix(16000)))
                hierarchy.name = "accessibility-hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
                capture("ios-failure")
            }
            app.terminate()
        }
        super.tearDown()
    }

    func testSharedTaskJourney() throws {
        continueAfterFailure = false
        let landscape = ProcessInfo.processInfo.environment["DIETER_IOS_TEST_LANDSCAPE"] == "1"
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        application = app
        app.launchEnvironment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("DIETER_IOS_TEST_") }
        app.launch()
        XCTAssertTrue(app.staticTexts["Your board"].waitForExistence(timeout: 40))
        if landscape { XCTAssertGreaterThan(app.frame.width, app.frame.height) }
        let seededTask = element(app, containing: "Design the mobile workspace")
        XCTAssertTrue(seededTask.waitForExistence(timeout: 40))
        capture("ios-board")
        seededTask.tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Your board stays within reach")
            ).firstMatch.waitForExistence(timeout: 20))
        if landscape {
            XCTAssertTrue(app.staticTexts["Your board"].isHittable, "Tablet keeps the board beside its conversation")
        }
        capture("ios-task")
        app.buttons["Back to board"].tap()
        app.buttons["New task"].tap()
        let title = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "Task title")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap(); title.typeText("A shared mobile conversation")
        let prompt = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "What should we do?")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap(); prompt.typeText("Explain how this task stays in one durable conversation.")
        capture("ios-new-task")
        if landscape { app.buttons["Hide keyboard"].tap() }
        // The system keyboard covers the lower half of the phone. Swipe within
        // the form's visible scroll area so the gesture reaches Compose.
        if !app.buttons["Start working"].isHittable {
            let form = app.scrollViews.firstMatch
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? min(form.frame.maxY, keyboard.frame.minY) : form.frame.maxY
            let origin = form.coordinate(withNormalizedOffset: .zero)
            // XCTest's Keyboard frame excludes the prediction/accessory row.
            let start = origin.withOffset(CGVector(dx: form.frame.width / 2, dy: bottom - form.frame.minY - 80))
            let end = origin.withOffset(CGVector(dx: form.frame.width / 2, dy: 40))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(app.buttons["Start working"].waitForExistence(timeout: 10))
        app.buttons["Start working"].tap()
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mock harness received:"))
            .firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 60))
        capture("ios-conversation")
        // Placeholder text disappears on focus. A tablet also keeps board search open.
        let composer = app.textViews.element(boundBy: landscape ? 1 : 0)
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        XCTAssertTrue(composer.isHittable, "Composer stays visible above the system keyboard")
        composer.typeText("Keep the same task and add the next step.")
        app.buttons["Send message"].tap()
        if landscape { app.buttons["Hide keyboard"].tap() }
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Mock harness received: Keep the same task")
            ).firstMatch
                .waitForExistence(timeout: 30))
        let review = app.buttons["Review"]
        XCTAssertTrue(review.waitForExistence(timeout: 60)); review.tap()
        app.buttons["Back to board"].tap()
        element(app, containing: "Review  ").tap()
        XCTAssertTrue(element(app, containing: "A shared mobile conversation").waitForExistence(timeout: 30))
        capture("ios-review")
        app.buttons["Machines"].tap()
        XCTAssertTrue(app.staticTexts["Your machines"].waitForExistence(timeout: 10))
        capture("ios-machines")
        app.terminate()
    }
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
