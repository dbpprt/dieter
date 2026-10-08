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
        XCTAssertTrue(element(app, containing: "Design the mobile workspace").waitForExistence(timeout: 40))
        capture("ios-inbox")
        app.buttons["Projects"].tap()
        XCTAssertTrue(element(app, containing: "Isolated E2E").waitForExistence(timeout: 20))
        if !element(app, containing: "Main").exists { element(app, containing: "Isolated E2E").tap() }
        XCTAssertTrue(element(app, containing: "Main").waitForExistence(timeout: 20))
        capture("ios-projects")
        element(app, containing: "Main").tap()
        assertRunningLane(app, landscape: landscape)
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
            XCTAssertTrue(app.staticTexts["Main"].isHittable, "Tablet keeps the board beside its conversation")
        }
        capture("ios-task")
        element(app, containing: "Subagents 1").tap()
        XCTAssertTrue(element(app, containing: "Layout scout").waitForExistence(timeout: 20))
        element(app, containing: "Layout scout").tap()
        capture("ios-subagents")
        app.buttons["Conversation"].tap()
        app.buttons["Back to board"].tap()
        app.buttons["native-new-task"].tap()
        let title = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "Task title")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap(); title.typeText("A shared mobile conversation")
        let hideKeyboard = app.buttons["Hide keyboard"].firstMatch
        XCTAssertTrue(waitForHittable(hideKeyboard), "Task header stays visible while editing the title")
        hideKeyboard.tap()
        let prompt = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "What should we do?")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap(); prompt.typeText("Explain how this task stays in one durable conversation.")
        capture("ios-new-task")
        XCTAssertTrue(waitForHittable(hideKeyboard), "Task header stays visible while editing the prompt")
        hideKeyboard.tap()
        // The full legacy form includes agent, workspace and label sections.
        // Scroll its gutter so a multiline field cannot consume the gesture.
        let form = app.scrollViews.firstMatch
        for _ in 0..<8 {
            if app.buttons["Start working"].exists && app.buttons["Start working"].isHittable { break }
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.82))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.2))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(app.buttons["Start working"].waitForExistence(timeout: 10))
        app.buttons["Start working"].tap()
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mock harness received:"))
            .firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 60))
        capture("ios-conversation")
        // The placeholder-based label changes on focus; the shared test tag
        // identifies this editor before and after the keyboard appears.
        let composer = app.textViews["message-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        let visibleComposer = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                composer.exists && composer.isHittable && composer.frame.maxY <= keyboard.frame.minY + 1
            }, object: composer)
        XCTAssertEqual(
            XCTWaiter.wait(for: [visibleComposer], timeout: 10), .completed,
            "Composer stays visible above the system keyboard")
        composer.typeText("Keep the same task and add the next step.")
        app.buttons["Send message"].tap()
        if landscape {
            keyboard.buttons["Hide keyboard"].tap()
            // iPadOS keeps a zero-height keyboard element after hiding it.
            let hidden = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !keyboard.exists || keyboard.frame.height < 1 }, object: keyboard)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed, "The system keyboard hides")
        }
        // Match the complete selectable reply across accessibility traits after
        // keyboard dismissal, then wait for native hit-testing to settle.
        let followUpReply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Mock harness received: Keep the same task and add the next step.")
        ).firstMatch
        XCTAssertTrue(
            followUpReply.waitForExistence(timeout: 30), "The follow-up reply appears in the same conversation")
        XCTAssertTrue(waitForHittable(followUpReply), "The follow-up reply is visible")
        let review = app.buttons["Review"]
        XCTAssertTrue(review.waitForExistence(timeout: 60)); review.tap()
        app.buttons["Back to board"].tap()
        if !landscape {
            element(app, containing: "Review  ").tap()
        } else {
            XCTAssertTrue(app.otherElements["board-lane-review"].exists)
        }
        XCTAssertTrue(element(app, containing: "A shared mobile conversation").waitForExistence(timeout: 30))
        capture("ios-review")
        app.buttons["Chats"].tap()
        XCTAssertTrue(element(app, containing: "Mobile release checklist").waitForExistence(timeout: 20))
        capture("ios-chats")
        app.buttons["Tools"].tap()
        XCTAssertTrue(element(app, containing: "Machines").waitForExistence(timeout: 10))
        capture("ios-tools")
        element(app, containing: "Machines").tap()
        XCTAssertTrue(element(app, containing: "Isolated E2E machine").waitForExistence(timeout: 20))
        capture("ios-machines")
        app.buttons["Back"].tap()
        element(app, containing: "Files").tap()
        XCTAssertTrue(element(app, containing: "README.md").waitForExistence(timeout: 20))
        capture("ios-files")
        element(app, containing: "README.md").tap()
        XCTAssertTrue(app.buttons["Preview Markdown"].waitForExistence(timeout: 20))
        app.buttons["Preview Markdown"].tap()
        XCTAssertTrue(element(app, containing: "One durable conversation").waitForExistence(timeout: 10))
        capture("ios-file-preview")
        app.buttons["Back to files"].tap()
        app.buttons["Back"].tap()
        element(app, containing: "Schedules").tap()
        XCTAssertTrue(element(app, containing: "Daily workspace review").waitForExistence(timeout: 20))
        capture("ios-schedules")
        app.buttons["Back"].tap()
        element(app, containing: "Settings").tap()
        XCTAssertTrue(element(app, containing: "Appearance").waitForExistence(timeout: 10))
        app.buttons["System"].tap()
        app.buttons["Dark"].tap()
        capture("ios-settings-dark")
        app.buttons["Projects"].tap()
        XCTAssertTrue(element(app, containing: "Main").waitForExistence(timeout: 20))
        element(app, containing: "Main").tap()
        assertRunningLane(app, landscape: landscape)
        capture("ios-board-dark")
        app.terminate()
    }
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
    private func waitForHittable(_ element: XCUIElement) -> Bool {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.exists && element.isHittable }, object: element)
        return XCTWaiter.wait(for: [hittable], timeout: 10) == .completed
    }
    private func assertRunningLane(_ app: XCUIApplication, landscape: Bool) {
        if landscape {
            XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 20))
            let lane = app.otherElements["board-lane-running"]
            XCTAssertTrue(lane.waitForExistence(timeout: 20))
            XCTAssertEqual(lane.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "card-")).count, 3)
        } else {
            XCTAssertTrue(element(app, containing: "Running  3").waitForExistence(timeout: 20))
        }
    }
    private func capture(_ name: String) {
        // Allow the Compose frame and SwiftUI appearance/chrome to be presented
        // after the accessibility assertion that selected this view.
        Thread.sleep(forTimeInterval: 0.35)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
