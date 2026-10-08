import XCTest

final class ComposeSpikeUITests: XCTestCase {
    private var application: XCUIApplication?

    override func tearDown() {
        if let app = application {
            // `hasSucceeded` is not final during tearDown; failures already recorded are.
            if (testRun?.totalFailureCount ?? 0) > 0 {
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

        tab(app, "Projects")
        XCTAssertTrue(app.staticTexts["Main"].waitForExistence(timeout: 20))
        capture("ios-projects")
        app.staticTexts["Main"].tap()
        let seededTask = element(app, containing: "Design the mobile workspace")
        XCTAssertTrue(seededTask.waitForExistence(timeout: 40))
        XCTAssertTrue(element(app, identifier: "lane-1").waitForExistence(timeout: 10), "Lane selector is visible")
        capture("ios-board")
        // In-content "…" buttons open a native UIMenu.
        let cardMenu = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "card-menu-")
        ).firstMatch
        XCTAssertTrue(cardMenu.waitForExistence(timeout: 10))
        cardMenu.tap()
        XCTAssertTrue(app.buttons["Move to"].waitForExistence(timeout: 5), "Card actions open as a native menu")
        capture("ios-card-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        Thread.sleep(forTimeInterval: 0.6)
        seededTask.tap()
        XCTAssertTrue(element(app, containing: "Your board stays within reach").waitForExistence(timeout: 20))
        if landscape {
            XCTAssertTrue(element(app, identifier: "lane-1").exists, "Tablet keeps the board beside its conversation")
        }
        capture("ios-task")

        // Native UIMenu from the conversation's bar button.
        app.buttons["chrome-conversation-menu"].firstMatch.tap()
        let subagents = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Subagents")).firstMatch
        XCTAssertTrue(subagents.waitForExistence(timeout: 10))
        subagents.tap()
        XCTAssertTrue(element(app, containing: "Layout scout").waitForExistence(timeout: 20))
        capture("ios-subagents")
        back(app)
        XCTAssertTrue(element(app, containing: "Your board stays within reach").waitForExistence(timeout: 20))
        if !landscape { back(app) }

        app.buttons["chrome-new-task"].firstMatch.tap()
        let title = element(app, identifier: "task-title")
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("A shared mobile conversation")
        let prompt = element(app, identifier: "task-prompt")
        prompt.tap()
        prompt.typeText("Explain how this task stays in one durable conversation.")
        XCTAssertTrue(app.buttons["chrome-start-working"].firstMatch.isHittable, "Start stays reachable while typing")
        capture("ios-new-task")
        app.buttons["chrome-start-working"].firstMatch.tap()
        let reply = element(app, containing: "Mock harness received:")
        XCTAssertTrue(reply.waitForExistence(timeout: 60))
        capture("ios-conversation")

        let composer = element(app, identifier: "message-input")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        XCTAssertTrue(composer.isHittable, "Composer stays visible above the system keyboard")
        composer.typeText("Keep the same task and add the next step.")
        element(app, identifier: "send-message").tap()
        XCTAssertTrue(
            element(app, containing: "Mock harness received: Keep the same task").waitForExistence(timeout: 30))
        let review = element(app, identifier: "move-review")
        XCTAssertTrue(review.waitForExistence(timeout: 60))
        review.tap()
        if !landscape { back(app) }
        let reviewLane = element(app, identifier: "lane-2")
        XCTAssertTrue(reviewLane.waitForExistence(timeout: 20))
        reviewLane.tap()
        XCTAssertTrue(element(app, containing: "A shared mobile conversation").waitForExistence(timeout: 30))
        capture("ios-review")

        tab(app, "Chats")
        XCTAssertTrue(element(app, containing: "Mobile release checklist").waitForExistence(timeout: 20))
        capture("ios-chats")
        tab(app, "Tools")
        XCTAssertTrue(element(app, identifier: "tool-machines").waitForExistence(timeout: 10))
        capture("ios-tools")
        element(app, identifier: "tool-machines").tap()
        XCTAssertTrue(element(app, containing: "Isolated E2E machine").waitForExistence(timeout: 20))
        capture("ios-machines")
        // On iPad each tool replaces the detail column beside the Tools list.
        if !landscape { back(app) }
        element(app, identifier: "tool-files").tap()
        XCTAssertTrue(element(app, containing: "README.md").waitForExistence(timeout: 20))
        capture("ios-files")
        element(app, containing: "README.md").tap()
        XCTAssertTrue(element(app, containing: "One durable conversation").waitForExistence(timeout: 20))
        capture("ios-file-preview")
        back(app)
        if !landscape { back(app) }
        element(app, identifier: "tool-schedules").tap()
        XCTAssertTrue(element(app, containing: "Daily workspace review").waitForExistence(timeout: 20))
        capture("ios-schedules")
        if !landscape { back(app) }
        let settings = element(app, identifier: "tool-settings")
        if !settings.isHittable { app.swipeUp() }
        settings.tap()
        XCTAssertTrue(element(app, identifier: "appearance-2").waitForExistence(timeout: 10))
        element(app, identifier: "appearance-2").tap()
        capture("ios-settings-dark")
        tab(app, "Projects")
        XCTAssertTrue(app.staticTexts["Main"].waitForExistence(timeout: 20))
        app.staticTexts["Main"].tap()
        XCTAssertTrue(element(app, identifier: "lane-1").waitForExistence(timeout: 20))
        capture("ios-board-dark")
        app.terminate()
    }

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func element(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Selects a tab from the tab bar or, on iPad, the sidebar, whose rows are not buttons.
    private func tab(_ app: XCUIApplication, _ title: String) {
        let bar = app.tabBars.buttons[title]
        if bar.exists && bar.isHittable { return bar.tap() }
        let types = [XCUIElement.ElementType.button, .cell, .other].map(\.rawValue)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND elementType IN %@", title, types)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(title) is reachable from the tab bar or sidebar")
        row.tap()
    }

    /// The native back button of the innermost navigation bar; on iPad, the detail column's.
    private func back(_ app: XCUIApplication) {
        let buttons = app.navigationBars.buttons.matching(identifier: "BackButton").allElementsBoundByIndex
        let button = buttons.filter({ $0.isHittable }).max(by: { $0.frame.minX < $1.frame.minX })
        XCTAssertNotNil(button, "A back button is visible")
        button?.tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func capture(_ name: String) {
        // Allow the Compose frame and native chrome to be presented after the
        // accessibility assertion that selected this view.
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
