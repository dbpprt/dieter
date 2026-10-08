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
        press(app.staticTexts["Main"])
        let seededTask = element(app, containing: "Design the mobile workspace")
        XCTAssertTrue(seededTask.waitForExistence(timeout: 40))
        XCTAssertTrue(element(app, identifier: "lane-1").waitForExistence(timeout: 10), "Lane selector is visible")
        capture("ios-board")
        // In-content "…" buttons open a native UIMenu.
        let cardMenu = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "card-menu-")
        ).firstMatch
        XCTAssertTrue(cardMenu.waitForExistence(timeout: 10))
        press(cardMenu)
        XCTAssertTrue(app.buttons["Move to"].waitForExistence(timeout: 5), "Card actions open as a native menu")
        capture("ios-card-menu")
        // Dismiss it on the navigation title, which has no action of its own; a tap on
        // the content could land on the search field once the menu has closed.
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitFor { !app.buttons["Move to"].exists }, "The card menu closes")
        press(seededTask)
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
        focus(title)
        title.typeText("A shared mobile conversation")
        XCTAssertTrue(waitForValue(title, containing: "A shared mobile conversation"), "The title holds the typed text")
        let prompt = element(app, identifier: "task-prompt")
        // Return moves on to the prompt, which also scrolls it above the keyboard; on an iPad
        // window the keyboard's shortcut bar can cover the prompt, so it is not tapped.
        title.typeText("\n")
        XCTAssertTrue(waitFor { self.hasKeyboardFocus(prompt) }, "Return in the title moves on to the prompt")
        let request = "Explain how this task stays in one durable conversation."
        prompt.typeText(request)
        // Compose applies typed text asynchronously; Start enables once the form holds it.
        XCTAssertTrue(waitForValue(prompt, containing: request), "The prompt holds the typed text")
        let start = app.buttons["chrome-start-working"].firstMatch
        XCTAssertTrue(waitForHittable(start), "Start stays reachable while typing")
        XCTAssertTrue(waitFor { start.isEnabled }, "Start enables once the form is complete")
        capture("ios-new-task")
        start.tap()
        let reply = element(app, containing: "Mock harness received:")
        // A mock turn on a loaded CI runner can take over 30 s to answer.
        XCTAssertTrue(reply.waitForExistence(timeout: 90))
        capture("ios-conversation")

        let composer = element(app, identifier: "message-input")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        focus(composer)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitFor { self.hasFrame(composer) && composer.frame.maxY <= keyboard.frame.minY + 1 },
            "Composer stays visible above the system keyboard")
        let followUp = "Keep the same task and add the next step."
        composer.typeText(followUp)
        // Sending before Compose applies every keystroke would submit a prefix.
        XCTAssertTrue(waitForValue(composer, containing: followUp), "The composer holds the whole message")
        let send = element(app, identifier: "send-message")
        press(send)
        if landscape {
            // An iPad window can leave the transcript little room above the keyboard; hide it
            // to read the reply. XCTest can keep reporting a hidden iPad keyboard, so the
            // reply checks below decide.
            let hide = keyboard.buttons["Hide keyboard"]
            if hide.exists { hide.tap() }
        }
        let followUpReply = element(app, containing: "Mock harness received: \(followUp)")
        XCTAssertTrue(
            followUpReply.waitForExistence(timeout: 90), "The follow-up reply appears in the same conversation")
        XCTAssertTrue(waitFor { self.isAbove(followUpReply, composer, in: app) }, "The follow-up reply is visible")
        // Reading earlier messages detaches the transcript; "Jump to latest" resumes following.
        let transcript = element(app, identifier: "conversation-timeline")
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        transcript.swipeDown()
        let jumpToLatest = element(app, containing: "Jump to latest")
        let detached = jumpToLatest.waitForExistence(timeout: 10)
        // On the tablet this short transcript can fit on screen, leaving nothing to scroll.
        if !landscape { XCTAssertTrue(detached, "Reading earlier messages detaches from the reply") }
        if detached {
            press(jumpToLatest)
            XCTAssertTrue(
                waitFor { self.isAbove(followUpReply, composer, in: app) },
                "Jumping to latest resumes following the reply")
        }
        let review = element(app, identifier: "move-review")
        XCTAssertTrue(review.waitForExistence(timeout: 60))
        press(review)
        if !landscape { back(app) }
        let reviewLane = element(app, identifier: "lane-2")
        XCTAssertTrue(reviewLane.waitForExistence(timeout: 20))
        press(reviewLane)
        XCTAssertTrue(element(app, containing: "A shared mobile conversation").waitForExistence(timeout: 30))
        capture("ios-review")

        tab(app, "Chats")
        XCTAssertTrue(element(app, containing: "Mobile release checklist").waitForExistence(timeout: 20))
        capture("ios-chats")
        tab(app, "Tools")
        XCTAssertTrue(element(app, identifier: "tool-machines").waitForExistence(timeout: 10))
        capture("ios-tools")
        press(element(app, identifier: "tool-machines"))
        XCTAssertTrue(element(app, containing: "Isolated E2E machine").waitForExistence(timeout: 20))
        capture("ios-machines")
        // On iPad each tool replaces the detail column beside the Tools list.
        if !landscape { back(app) }
        press(element(app, identifier: "tool-files"))
        XCTAssertTrue(element(app, containing: "README.md").waitForExistence(timeout: 20))
        capture("ios-files")
        press(element(app, containing: "README.md"))
        XCTAssertTrue(element(app, containing: "One durable conversation").waitForExistence(timeout: 20))
        capture("ios-file-preview")
        back(app)
        if !landscape { back(app) }
        press(element(app, identifier: "tool-schedules"))
        XCTAssertTrue(element(app, containing: "Daily workspace review").waitForExistence(timeout: 20))
        capture("ios-schedules")
        if !landscape { back(app) }
        let settings = element(app, identifier: "tool-settings")
        // Settings is the last tool row; bring it above the tab bar on phones.
        if !waitFor(timeout: 3, { self.hasFrame(settings) && settings.frame.maxY < app.frame.maxY - 120 }) {
            app.swipeUp()
        }
        press(settings)
        XCTAssertTrue(element(app, identifier: "appearance-2").waitForExistence(timeout: 10))
        press(element(app, identifier: "appearance-2"))
        capture("ios-settings-dark")
        tab(app, "Projects")
        XCTAssertTrue(app.staticTexts["Main"].waitForExistence(timeout: 20))
        press(app.staticTexts["Main"])
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
        if hasFrame(bar) && bar.isHittable { return bar.tap() }
        let types = [XCUIElement.ElementType.button, .cell, .other].map(\.rawValue)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND elementType IN %@", title, types)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(title) is reachable from the tab bar or sidebar")
        row.tap()
    }

    /// The native back button of the innermost navigation bar; on iPad, the detail column's.
    private func back(_ app: XCUIApplication) {
        let buttons = app.navigationBars.buttons.matching(identifier: "BackButton").allElementsBoundByIndex
        let button = buttons.filter({ hasFrame($0) && $0.isHittable }).max(by: { $0.frame.minX < $1.frame.minX })
        XCTAssertNotNil(button, "A back button is visible")
        button?.tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// `isHittable` records a failure for elements without an activation point; check the frame first.
    private func hasFrame(_ element: XCUIElement) -> Bool {
        element.exists && !element.frame.isEmpty
    }

    private func waitFor(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        waitFor(timeout: timeout) { self.hasFrame(element) && element.isHittable }
    }

    /// Taps a Compose element where it is drawn. On iOS 26 XCTest's hit-test check can
    /// resolve a nested Compose control to its container, although touches reach it. With
    /// the keyboard up, the tap goes to the element's visible part above it.
    private func press(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitFor { self.hasFrame(element) }, "\(element) is on screen", file: file, line: line)
        let frame = element.frame
        var y = frame.midY
        let keyboard = XCUIApplication().keyboards.firstMatch
        if hasFrame(keyboard) && keyboard.frame.height > 1 && y > keyboard.frame.minY - 8 {
            y = max(frame.minY + 4, keyboard.frame.minY - 8)
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (y - frame.minY) / frame.height)).tap()
    }

    /// Inside the window and fully above [bottom], e.g. a reply clear of the composer.
    private func isAbove(_ element: XCUIElement, _ bottom: XCUIElement, in app: XCUIApplication) -> Bool {
        hasFrame(element) && hasFrame(bottom) && element.frame.minY >= app.frame.minY
            && element.frame.maxY <= bottom.frame.minY + 1
    }

    /// Taps a Compose text field until it holds keyboard focus; Compose moves focus after
    /// the touch, so typing straight away can reach the previously focused field.
    private func focus(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 {
            press(field, file: file, line: line)
            if waitFor(timeout: 5, { self.hasKeyboardFocus(field) }) { return }
        }
        XCTFail("\(field) takes keyboard focus", file: file, line: line)
    }

    private func hasKeyboardFocus(_ field: XCUIElement) -> Bool {
        (field.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    private func waitForValue(_ element: XCUIElement, containing text: String) -> Bool {
        waitFor { (element.value as? String)?.contains(text) == true }
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
