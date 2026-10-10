import XCTest

final class JourneyUITests: XCTestCase {
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
        pullToRefresh(app, identifier: "inbox-refresh")
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
        // Typing goes to the focused field and each field's value proves where it went: the
        // per-element focus probe and typeText check are unreliable on loaded CI runners.
        focus(title, in: app)
        app.typeText("A shared mobile conversation")
        XCTAssertTrue(waitForValue(title, containing: "A shared mobile conversation"), "The title holds the typed text")
        let prompt = element(app, identifier: "task-prompt")
        // Return moves on to the prompt, which also scrolls it above the keyboard; on an iPad
        // window the keyboard's shortcut bar can cover the prompt, so it is not tapped.
        app.typeText("\n")
        _ = waitFor(timeout: 5) { self.hasKeyboardFocus(prompt) }
        let request = "Explain how this task stays in one durable conversation."
        app.typeText(request)
        // Compose applies typed text asynchronously; Start enables once the form holds it.
        XCTAssertTrue(
            waitForValue(prompt, containing: request), "Return moved on to the prompt, which holds the request")
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
        focus(composer, in: app)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitFor { self.hasFrame(composer) && composer.frame.maxY <= keyboard.frame.minY + 1 },
            "Composer stays visible above the system keyboard")
        let followUp = "Keep the same task and add the next step."
        app.typeText(followUp)
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
        pullToRefresh(app, identifier: "chats-refresh")
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

    /// A file shared from Files through the Dieter extension opens New Task when Dieter is reopened.
    func testShareExtensionStartsATask() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["DIETER_IOS_TEST_LANDSCAPE"] != "1" else {
            throw XCTSkip("The phone journey covers the compact Files share sheet")
        }
        let ownedFile = try XCTUnwrap(environment["DIETER_IOS_TEST_SHARE_FILE"])
        XCUIDevice.shared.orientation = .portrait
        // Sign the app in before Files hands it the share, then stop it, so reopening
        // exercises the persisted cold-start handoff.
        let app = XCUIApplication()
        application = app
        app.launchEnvironment = environment.filter { $0.key.hasPrefix("DIETER_IOS_TEST_") }
        app.launch()
        XCTAssertTrue(element(app, containing: "Design the mobile workspace").waitForExistence(timeout: 40))
        app.terminate()

        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let borrowedFiles = files.state != .notRunning
        addTeardownBlock { if !borrowedFiles { files.terminate() } }
        openOwnedFileShare(files, filename: ownedFile)
        let dieter = files.cells.matching(
            NSPredicate(format: "identifier == 'shareCell' AND label IN %@", ["Dieter E2E", "Dieter"])
        ).firstMatch
        XCTAssertTrue(
            dieter.waitForExistence(timeout: 15),
            "The installed Dieter share extension must appear in the share sheet.\n\(files.debugDescription)")
        dieter.tap()
        XCTAssertTrue(
            files.staticTexts["Where should this go?"].waitForExistence(timeout: 20),
            "The Dieter share extension must finish staging the file.\n\(files.debugDescription)")
        capture("ios-share-destination")
        let newTask = files.buttons.matching(identifier: "ios.share.new-task").firstMatch
        XCTAssertTrue(newTask.waitForExistence(timeout: 5))
        newTask.tap()
        XCTAssertTrue(
            files.staticTexts["Ready in Dieter. Tap Done, then open Dieter to continue."].waitForExistence(timeout: 10),
            "The share extension must confirm the handoff.\n\(files.debugDescription)")
        let done = files.buttons.matching(identifier: "ios.share.done").firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()

        // Reopening the stopped app consumes the app group request into New Task.
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(
            element(app, identifier: "task-prompt").waitForExistence(timeout: 45),
            "The shared request must open New Task.\n\(app.debugDescription)")
        XCTAssertTrue(
            element(app, containing: ownedFile).waitForExistence(timeout: 15),
            "New Task must hold the exact file shared from Files.\n\(app.debugDescription)")
        capture("ios-share-new-task")

        // The shared file starts a turn with the request typed beside it.
        let prompt = element(app, identifier: "task-prompt")
        focus(prompt, in: app)
        let request = "Review the shared file."
        app.typeText(request)
        XCTAssertTrue(waitForValue(prompt, containing: request), "The prompt holds the request")
        let start = app.buttons["chrome-start-working"].firstMatch
        XCTAssertTrue(waitForHittable(start), "Start stays reachable while typing")
        XCTAssertTrue(waitFor { start.isEnabled }, "Start enables once the form is complete")
        start.tap()
        XCTAssertTrue(
            element(app, containing: "Mock harness received: \(request)").waitForExistence(timeout: 90),
            "The shared task must start a turn.\n\(app.debugDescription)")
        XCTAssertTrue(
            element(app, containing: ownedFile).waitForExistence(timeout: 15),
            "The conversation must keep the shared file.\n\(app.debugDescription)")
        capture("ios-share-conversation")
    }

    private func openOwnedFileShare(_ files: XCUIApplication, filename: String) {
        if files.state == .notRunning { files.launch() } else { files.activate() }
        XCTAssertTrue(files.wait(for: .runningForeground, timeout: 20))
        let browse = files.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "Durchsuchen"]))
            .firstMatch
        if browse.waitForExistence(timeout: 10) {
            browse.tap()
            browse.tap()
        }
        let location = files.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["On My iPhone", "On My iPad", "Auf meinem iPhone", "Auf meinem iPad"])
        ).firstMatch
        for _ in 0..<5 {
            if location.waitForExistence(timeout: 2) { break }
            let back = files.navigationBars.buttons.firstMatch
            guard back.exists && back.isHittable else { break }
            back.tap()
        }
        XCTAssertTrue(
            location.waitForExistence(timeout: 10), "Files must expose local storage.\n\(files.debugDescription)")
        location.tap()
        let directory = files.staticTexts["Dieter E2E"]
        XCTAssertTrue(
            directory.waitForExistence(timeout: 15),
            "The owned E2E container must appear in Files.\n\(files.debugDescription)")
        directory.tap()
        let name = (filename as NSString).deletingPathExtension
        let image = files.staticTexts.matching(NSPredicate(format: "label IN %@", [filename, name])).firstMatch
        XCTAssertTrue(
            image.waitForExistence(timeout: 15), "Files must expose the exact owned file.\n\(files.debugDescription)")
        image.press(forDuration: 1)
        let share = files.buttons.matching(
            NSPredicate(format: "label IN %@", ["Share", "Share…", "Teilen", "Teilen …"])
        )
        .firstMatch
        XCTAssertTrue(
            share.waitForExistence(timeout: 10), "The owned file must expose Share.\n\(files.debugDescription)")
        let shareSheet = files.cells.matching(identifier: "shareCell").firstMatch
        for attempt in 0..<2 {
            // Files can leave the context menu open after an element tap: tap the
            // verified geometry, then require the activity sheet before moving on.
            let frame = share.frame
            guard frame.minX.isFinite, frame.minY.isFinite, frame.width > 0, frame.height > 0,
                files.frame.contains(frame)
            else {
                XCTFail("Files Share must have a finite visible frame.\n\(files.debugDescription)")
                return
            }
            files.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            if shareSheet.waitForExistence(timeout: 5) { return }
            guard attempt == 0, !shareSheet.exists, share.exists else { break }
        }
        XCTAssertTrue(
            shareSheet.waitForExistence(timeout: 10),
            "Files Share must open the activity sheet.\n\(files.debugDescription)")
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

    private func pullToRefresh(_ app: XCUIApplication, identifier: String) {
        let list = element(app, identifier: identifier)
        XCTAssertTrue(waitFor { self.hasFrame(list) }, "The refreshable list is visible")
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93))
        start.press(forDuration: 0.1, thenDragTo: end)
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
        guard waitFor(timeout: 5, { self.hasFrame(element) }) else {
            // On a loaded CI runner XCTest can report no frame while the keyboard is up; use
            // its own hit point instead.
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) exists", file: file, line: line)
            element.tap()
            return
        }
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

    /// Taps a Compose text field once and waits for the keyboard; Compose moves focus after
    /// the touch, so give it a moment before typing.
    private func focus(
        _ field: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        press(field, file: file, line: line)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 10), "\(field) shows the keyboard", file: file,
            line: line)
        _ = waitFor(timeout: 5) { self.hasKeyboardFocus(field) }
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
