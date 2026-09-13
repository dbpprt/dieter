import XCTest

@MainActor
final class RemoteNodeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let button = app.buttons.matching(identifier: identifier).firstMatch
        if button.exists { return button }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 20) {
        let control = element(app, identifier)
        XCTAssertTrue(control.waitForExistence(timeout: timeout), "Missing \(identifier).\n\(app.debugDescription)")
        control.tap()
    }

    private func enter(_ app: XCUIApplication, _ identifier: String, _ text: String) {
        let field = element(app, identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Missing \(identifier)")
        field.tap()
        dismissKeyboardIntroduction(app)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 10),
            "Tapping \(identifier) should activate text input.\n\(app.debugDescription)")
        field.typeText(text)
        dismissKeyboardIntroduction(app)
    }

    private func dismissKeyboardIntroduction(_ app: XCUIApplication) {
        // A fresh simulator can inherit the host’s bilingual keyboard and show
        // its first-use introduction above the keys. Handle that system UI,
        // rather than tapping an obscured app toolbar through it.
        let introduction = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'same keyboard'")
        ).firstMatch
        if introduction.waitForExistence(timeout: 1) {
            let next = app.buttons["Continue"]
            XCTAssertTrue(next.isHittable)
            next.tap()
        }
    }

    private func fillTask(_ app: XCUIApplication, title: String, prompt: String) {
        // Configure the isolated provider while submission is still disabled.
        // A compact iPad sheet scrolls the Agent section beneath its fixed footer.
        let provider = element(app, "ios.create.provider")
        XCTAssertTrue(provider.waitForExistence(timeout: 10))
        let form = app.collectionViews.containing(.button, identifier: "ios.create.provider").firstMatch
        let footer = element(app, "ios.create.run")
        for _ in 0..<4 {
            if provider.frame.maxY < footer.frame.minY - 8 && provider.isHittable { break }
            XCTAssertTrue(form.exists)
            form.swipeUp()
        }
        XCTAssertLessThan(
            provider.frame.maxY, footer.frame.minY - 8, "Provider must be above the footer before tapping.")
        tap(app, "ios.create.provider")
        let mock = app.buttons.matching(NSPredicate(format: "label == 'Mock'")).firstMatch
        XCTAssertTrue(mock.waitForExistence(timeout: 5), app.debugDescription)
        mock.tap()
        let providerChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'Mock'"), object: element(app, "ios.create.provider"))
        XCTAssertEqual(XCTWaiter.wait(for: [providerChanged], timeout: 5), .completed)
        // Return to the first form section after selecting the provider.
        for _ in 0..<4 {
            let titleField = element(app, "ios.create.title")
            if titleField.isHittable && titleField.frame.minY >= form.frame.minY { break }
            form.swipeDown()
        }
        enter(app, "ios.create.title", title)
        enter(app, "ios.create.prompt", prompt)
        tap(app, "ios.create.keyboard-done")
        let keyboardGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 5), .completed, app.debugDescription)
    }

    private func textExists(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 30) {
        let label = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: timeout), "Missing text \(text).\n\(app.debugDescription)")
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testHTTPSGatewayRejectsInvalidSession() throws {
        guard let gateway = ProcessInfo.processInfo.environment["DIETER_IOS_TEST_HTTPS_GATEWAY"] else {
            throw XCTSkip("Pass --https-gateway to verify an HTTPS gateway without authenticating")
        }
        let app = XCUIApplication()
        app.launchEnvironment["DIETER_IOS_TEST_GATEWAY"] = gateway
        app.launchEnvironment["DIETER_IOS_TEST_TOKEN"] = "invalid-ios-tls-probe"
        app.launch()
        XCTAssertTrue(
            app.alerts.staticTexts["authentication required"].waitForExistence(timeout: 35),
            "Expected the HTTPS gateway’s explicit invalid-session response.\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "ios.auth").exists)
        XCTAssertFalse(element(app, "ios.workspace").exists)
        screenshot(app, "00-verified-https-auth-rejection")
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(element(app, "ios.auth.sign-in").isHittable)
    }

    func testRemoteNodeJourney() throws {
        let environment = ProcessInfo.processInfo.environment
        let gateway = try XCTUnwrap(environment["DIETER_IOS_TEST_GATEWAY"])
        let token = try XCTUnwrap(environment["DIETER_IOS_TEST_TOKEN"])
        let project = try XCTUnwrap(environment["DIETER_IOS_TEST_PROJECT"])
        let board = try XCTUnwrap(environment["DIETER_IOS_TEST_BOARD"])
        if environment["DIETER_IOS_TEST_LANDSCAPE"] == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let app = XCUIApplication()
        app.launchEnvironment["DIETER_IOS_TEST_GATEWAY"] = gateway
        app.launchEnvironment["DIETER_IOS_TEST_TOKEN"] = token
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        textExists(app, "Isolated E2E", timeout: 40)
        screenshot(app, "01-connected-remote-projects")
        if !element(app, "ios.board.\(board)").exists {
            tap(app, "ios.project.\(project)")
        }
        tap(app, "ios.board.\(board)")
        if element(app, "ios.list.new-task").exists { tap(app, "ios.list.new-task") } else { tap(app, "ios.new-task") }
        fillTask(app, title: "iOS remote smoke task", prompt: "Verify this request came from iOS")
        screenshot(app, "02-create-remote-task")
        let runReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true AND enabled == true"),
            object: element(app, "ios.create.run"))
        XCTAssertEqual(
            XCTWaiter.wait(for: [runReady], timeout: 5), .completed,
            "Run task should remain visible and enabled after entering the task.\n\(app.debugDescription)")
        tap(app, "ios.create.run")
        textExists(app, "Mock harness received: Verify this request came from iOS", timeout: 90)
        screenshot(app, "03-live-remote-conversation")
        enter(app, "ios.composer.message", "Continue from the same iOS conversation")
        tap(app, "ios.composer.send")
        textExists(app, "Mock harness received: Continue from the same iOS conversation", timeout: 60)
        screenshot(app, "04-follow-up")
        tap(app, "ios.task.actions")
        tap(app, "ios.task.files")
        tap(app, "ios.files.entry.README.md")
        let editor = element(app, "ios.files.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertTrue((editor.value as? String)?.contains("Isolated E2E") == true)
        // UITextView’s accessibility frame includes the full sheet. Target the
        // visible first text line beneath its breadcrumb, not the blank center.
        let breadcrumb = element(app, "ios.files.path")
        XCTAssertTrue(breadcrumb.waitForExistence(timeout: 5))
        editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 40, dy: breadcrumb.frame.maxY - editor.frame.minY + 20)).tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 5),
            "Tapping the file editor should activate text input.\n\(app.debugDescription)")
        editor.typeText("\niOS remote edit verified\n")
        let editedContents = try XCTUnwrap(editor.value as? String)
        tap(app, "ios.files.save")
        let saved = NSPredicate(format: "enabled == false")
        expectation(for: saved, evaluatedWith: element(app, "ios.files.save"))
        waitForExpectations(timeout: 15)
        tap(app, "ios.files.back")
        tap(app, "ios.files.entry.README.md")
        XCTAssertTrue(element(app, "ios.files.editor").waitForExistence(timeout: 15))
        XCTAssertEqual(element(app, "ios.files.editor").value as? String, editedContents)
        XCTAssertTrue(editedContents.contains("iOS remote edit verified"))
        screenshot(app, "05-remote-file-edit")
        // Relaunch must rediscover the node and retain the daemon-owned task.
        app.terminate()
        app.launch()
        textExists(app, "Isolated E2E", timeout: 40)
        if !element(app, "ios.board.\(board)").exists { tap(app, "ios.project.\(project)") }
        tap(app, "ios.board.\(board)")
        textExists(app, "iOS remote smoke task")
        screenshot(app, "06-task-survives-relaunch")

        if element(app, "ios.list.new-task").exists { tap(app, "ios.list.new-task") } else { tap(app, "ios.new-task") }
        fillTask(app, title: "iOS draft smoke task", prompt: "Start the saved iOS draft")
        tap(app, "ios.create.add")
        textExists(app, "Ready when you are")
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'Mock harness received: Start the saved iOS draft'")
            ).firstMatch.exists)
        tap(app, "ios.task.start")
        textExists(app, "Mock harness received: Start the saved iOS draft", timeout: 60)
        screenshot(app, "07-draft-started")

        XCUIDevice.shared.press(.home)
        app.activate()
        textExists(app, "Mock harness received: Start the saved iOS draft", timeout: 40)
        enter(app, "ios.composer.message", "Continue after foreground reconnect")
        tap(app, "ios.composer.send")
        textExists(app, "Mock harness received: Continue after foreground reconnect", timeout: 60)
        screenshot(app, "08-foreground-reconnected")

        app.terminate()
        app.launch()
        textExists(app, "Isolated E2E", timeout: 40)
        let legacy = try XCTUnwrap(environment["DIETER_IOS_TEST_LEGACY_DAEMON"])
        let daemon = try XCTUnwrap(environment["DIETER_IOS_TEST_DAEMON"])
        tap(app, "ios.machine-picker")
        tap(app, "ios.machine.\(legacy)")
        textExists(app, "This machine uses API 2", timeout: 20)
        screenshot(app, "09-legacy-node-rejected")
        app.alerts.buttons["OK"].tap()
        tap(app, "ios.machine-picker")
        tap(app, "ios.machine.\(daemon)")
        textExists(app, "Isolated E2E", timeout: 40)
        XCTAssertTrue(element(app, "ios.board.\(board)").waitForExistence(timeout: 20))
        screenshot(app, "10-compatible-node-restored")
    }
}
