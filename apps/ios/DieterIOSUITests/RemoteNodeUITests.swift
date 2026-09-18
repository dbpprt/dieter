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
        let button = app.buttons.matching(identifier: identifier).firstMatch
        if button.exists {
            // Keyboard accessory buttons can disappear between two consecutive
            // accessibility snapshots on iPad. Tap the resolved button before
            // asking XCTest for another snapshot.
            button.tap()
            return
        }
        let control = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: timeout), "Missing \(identifier).\n\(app.debugDescription)")
        control.tap()
    }

    private func enter(_ app: XCUIApplication, _ identifier: String, _ text: String) {
        // All editable journey fields are native text fields. Query that small
        // type directly: a descendant `.any` lookup can stall while snapshotting
        // the complete iPad split view and then falsely report the field missing.
        let field = app.textFields.matching(identifier: identifier).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Missing \(identifier)")
        let keyboard = app.keyboards.firstMatch
        var activated = false
        for attempt in 0..<2 {
            field.tap()
            if keyboard.waitForExistence(timeout: 5) {
                dismissKeyboardIntroduction(app)
                activated = true
                break
            }
            // iPad CI can leave a first native text-field tap unconsumed after
            // the transcript updates. Retry once while the field is hittable.
            guard attempt == 0, field.isHittable else { break }
        }
        XCTAssertTrue(
            activated, "Tapping \(identifier) should activate text input.\n\(app.debugDescription)")
        field.typeText(text)
        dismissKeyboardIntroduction(app)
    }

    private func dismissKeyboardIntroduction(_ app: XCUIApplication) {
        // A fresh simulator can inherit the host’s bilingual keyboard and show
        // its first-use introduction above the keys. Handle that system UI,
        // rather than tapping an obscured app toolbar through it.
        // Resolve its action directly: asking XCTest for the broad static-text
        // snapshot can hang on iPad when SwiftUI exposes duplicate descendants.
        let continueButton = app.buttons.matching(identifier: "Continue").firstMatch
        if continueButton.exists {
            continueButton.tap()
        }
    }

    private func tapPicker(_ picker: XCUIElement) {
        if picker.isHittable {
            picker.tap()
        } else {
            // Xcode 26.5 can keep reporting a fully visible SwiftUI Picker as
            // non-hittable after the app relaunches and presents this sheet a
            // second time. Its resolved frame still receives native events.
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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
        XCTAssertGreaterThanOrEqual(
            provider.frame.minY, form.frame.minY, "Provider must be inside the visible form before tapping.")
        let providerReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: provider)
        _ = XCTWaiter.wait(for: [providerReady], timeout: 5)
        let previousProvider = provider.value as? String
        tapPicker(provider)
        let openingOption = app.buttons.matching(NSPredicate(format: "label == 'Mock'")).firstMatch
        if !openingOption.waitForExistence(timeout: 5), !openingOption.exists,
            provider.exists, let previousProvider,
            provider.value as? String == previousProvider
        {
            // A native picker can leave an opening tap unconsumed after relaunch.
            // Retry once only while no option appeared and the selection is unchanged.
            tapPicker(provider)
        }
        var mockSelected = false
        for attempt in 0..<2 {
            let mock = app.buttons.matching(NSPredicate(format: "label == 'Mock'")).firstMatch
            let optionReady = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND hittable == true"), object: mock)
            XCTAssertEqual(
                XCTWaiter.wait(for: [optionReady], timeout: 5), .completed,
                "The Mock provider option must be hittable.\n\(app.debugDescription)")
            mock.tap()
            let providerChanged = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == 'Mock'"), object: provider)
            let providerResult = XCTWaiter.wait(for: [providerChanged], timeout: 5)
            if providerResult == .completed || provider.value as? String == "Mock" {
                mockSelected = true
                break
            }
            // CI recorded an unconsumed native menu tap. Retry once only while
            // that option remains hittable and the provider is still unchanged.
            let remainingMock = app.buttons.matching(NSPredicate(format: "label == 'Mock'")).firstMatch
            guard attempt == 0, remainingMock.isHittable,
                let previousProvider, provider.value as? String == previousProvider
            else { break }
        }
        XCTAssertTrue(
            mockSelected, "Selecting Mock must update the provider.\n\(app.debugDescription)")
        // Native Picker labels vary by OS; the value describes the selection.
        // Verify the dependent model reset as well before submitting anything.
        for identifier in ["ios.create.provider", "ios.create.model"] {
            let picker = element(app, identifier)
            let selectedMock = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == 'Mock'"), object: picker)
            let selectionResult = XCTWaiter.wait(for: [selectedMock], timeout: 5)
            XCTAssertTrue(
                selectionResult == .completed || picker.value as? String == "Mock",
                "\(identifier) should select Mock; label=\(picker.label), value=\(String(describing: picker.value)).\n\(app.debugDescription)"
            )
        }
        // Return to the first form section after selecting the provider.
        for _ in 0..<4 {
            let titleField = app.textFields.matching(identifier: "ios.create.title").firstMatch
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

    private func assistantTextExists(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 60) {
        // Match the small set of transcript text nodes by identifier before
        // inspecting their labels. A broad StaticText query repeatedly snapshots
        // the entire iPad split view and can starve the fixture data plane.
        let label = app.staticTexts.matching(identifier: "ios.message.text.assistant")
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(
            label.waitForExistence(timeout: timeout),
            "Missing assistant text \(text).\n\(app.debugDescription)")
    }

    private func waitForBoard(_ app: XCUIApplication, project: String, board: String) {
        // The machine name appears before its workspace loads. Project links
        // navigate away from the sidebar; board links are their siblings.
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element(app, "ios.board.\(board)"))
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 40), .completed,
            "The fixture board must be ready in the sidebar.\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "ios.project.\(project)").exists, "The fixture project must be present.")
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
        waitForBoard(app, project: project, board: board)
        screenshot(app, "01-connected-remote-projects")
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
        assistantTextExists(app, "Mock harness received: Verify this request came from iOS", timeout: 150)
        screenshot(app, "03-live-remote-conversation")
        enter(app, "ios.composer.message", "Continue from the same iOS conversation")
        tap(app, "ios.composer.send")
        assistantTextExists(app, "Mock harness received: Continue from the same iOS conversation")
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
        waitForBoard(app, project: project, board: board)
        tap(app, "ios.board.\(board)")
        textExists(app, "iOS remote smoke task")
        screenshot(app, "06-task-survives-relaunch")

        if element(app, "ios.list.new-task").exists { tap(app, "ios.list.new-task") } else { tap(app, "ios.new-task") }
        fillTask(app, title: "iOS draft smoke task", prompt: "Start the saved iOS draft")
        tap(app, "ios.create.add")
        textExists(app, "Ready when you are")
        XCTAssertFalse(
            app.staticTexts.matching(identifier: "ios.message.text.assistant")
                .matching(NSPredicate(format: "label CONTAINS 'Mock harness received: Start the saved iOS draft'"))
                .firstMatch.exists)
        tap(app, "ios.task.start")
        assistantTextExists(app, "Mock harness received: Start the saved iOS draft")
        screenshot(app, "07-draft-started")

        XCUIDevice.shared.press(.home)
        app.activate()
        assistantTextExists(app, "Mock harness received: Start the saved iOS draft", timeout: 40)
        enter(app, "ios.composer.message", "Continue after foreground reconnect")
        tap(app, "ios.composer.send")
        assistantTextExists(app, "Mock harness received: Continue after foreground reconnect")
        screenshot(app, "08-foreground-reconnected")

        app.terminate()
        app.launch()
        waitForBoard(app, project: project, board: board)
        let legacy = try XCTUnwrap(environment["DIETER_IOS_TEST_LEGACY_DAEMON"])
        let daemon = try XCTUnwrap(environment["DIETER_IOS_TEST_DAEMON"])
        tap(app, "ios.machine-picker")
        tap(app, "ios.machine.\(legacy)")
        textExists(app, "This machine uses API 2", timeout: 20)
        screenshot(app, "09-legacy-node-rejected")
        app.alerts.buttons["OK"].tap()
        tap(app, "ios.machine-picker")
        tap(app, "ios.machine.\(daemon)")
        waitForBoard(app, project: project, board: board)
        screenshot(app, "10-compatible-node-restored")

        if environment["DIETER_IOS_TEST_LANDSCAPE"] != "1" {
            tap(app, "ios.screens.open")
            XCTAssertTrue(element(app, "ios.screens.back").waitForExistence(timeout: 10))
            XCTAssertTrue(element(app, "ios.screens.settings").isHittable)
            let window = app.windows.firstMatch
            let landscape = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in window.frame.width > window.frame.height }, object: window)
            XCTAssertEqual(
                XCTWaiter.wait(for: [landscape], timeout: 10), .completed,
                "The iPhone screen viewer should request landscape automatically.\n\(app.debugDescription)")
            screenshot(app, "11-remote-screen-phone-chrome")
            tap(app, "ios.screens.back")
            let portrait = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in window.frame.height > window.frame.width }, object: window)
            XCTAssertEqual(
                XCTWaiter.wait(for: [portrait], timeout: 10), .completed,
                "Leaving the iPhone screen viewer should restore portrait.\n\(app.debugDescription)")
        }
    }
}
