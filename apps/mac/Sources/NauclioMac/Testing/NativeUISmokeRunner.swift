import AppKit
import Foundation

/// An in-process smoke driver for a native app.
///
/// Events are delivered to Nauclio's own NSWindow and snapshots are read from its
/// own content view. This exercises the same SwiftUI button hit-testing as a
/// person while requiring neither Accessibility nor Screen Recording access.
@MainActor
enum NativeUISmokeRunner {
    private struct Step {
        let name: String
        let section: AppSection
        let distanceFromTop: CGFloat
    }

    static func run(store: NauclioStore) async {
        let output = outputDirectory()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? await NauclioTaskSleep.seconds(1)

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Nauclio" })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            writeReport(["error": "Nauclio window not found"], to: output)
            return
        }

        window.setContentSize(NSSize(width: 1_380, height: 870))
        window.center()
        window.makeKeyAndOrderFront(nil)
        try? await NauclioTaskSleep.milliseconds(500)

        var results: [String: String] = [:]
        capture(window, to: output.appending(path: "01-board.png"))
        results["board-initial"] = store.section.rawValue

        click(window: window, x: 164, distanceFromTop: 54)
        try? await NauclioTaskSleep.milliseconds(500)
        capture(window, to: output.appending(path: "01b-navigation-collapsed.png"))
        click(window: window, x: 29, distanceFromTop: 151)
        try? await NauclioTaskSleep.seconds(1)
        results["navigation-collapse"] = store.section == .chats ? "passed" : "failed: collapsed rail did not navigate"
        click(window: window, x: 29, distanceFromTop: 58)
        try? await NauclioTaskSleep.milliseconds(500)
        click(window: window, x: 55, distanceFromTop: 216)
        try? await NauclioTaskSleep.milliseconds(700)

        let steps = [Step(name: "02-global-chats", section: .chats, distanceFromTop: 145)]
        for step in steps {
            click(window: window, x: 80, distanceFromTop: step.distanceFromTop)
            try? await NauclioTaskSleep.seconds(1)
            results[step.name] = store.section == step.section ? "passed" : "failed: \(store.section.rawValue)"
            capture(window, to: output.appending(path: "\(step.name).png"))
        }

        click(window: window, x: 450, distanceFromTop: 283)
        try? await NauclioTaskSleep.seconds(1)
        results["03-standalone-chat"] = store.selectedChatID == nil ? "failed: no standalone chat selected" : "passed"
        capture(window, to: output.appending(path: "03-standalone-chat.png"))

        let remaining = [
            Step(name: "04-project-files", section: .files, distanceFromTop: 252),
            Step(name: "05-project-schedules", section: .schedules, distanceFromTop: 286),
            Step(name: "06-board", section: .board, distanceFromTop: 216),
        ]
        for step in remaining {
            click(window: window, x: 55, distanceFromTop: step.distanceFromTop)
            try? await NauclioTaskSleep.seconds(1)
            results[step.name] = store.section == step.section ? "passed" : "failed: \(store.section.rawValue)"
            capture(window, to: output.appending(path: "\(step.name).png"))
        }

        click(window: window, x: 650, distanceFromTop: 210)
        try? await NauclioTaskSleep.seconds(1)
        results["07-card-conversation"] = store.selectedCardID == nil ? "failed: no card selected" : "passed"
        capture(window, to: output.appending(path: "07-card-conversation.png"))

        store.openSettings()
        try? await NauclioTaskSleep.milliseconds(700)
        results["09-settings-general"] = store.section == .settings ? "passed" : "failed: settings did not open"
        capture(window, to: output.appending(path: "09-settings-general.png"))

        click(window: window, x: 320, distanceFromTop: 165)
        try? await NauclioTaskSleep.milliseconds(700)
        capture(window, to: output.appending(path: "10-settings-connection.png"))
        results["10-settings-connection"] = "passed"

        click(window: window, x: 320, distanceFromTop: 204)
        try? await NauclioTaskSleep.seconds(1)
        capture(window, to: output.appending(path: "11-settings-prompts.png"))
        results["11-settings-prompts"] = "passed"

        store.section = .board
        store.labelsPresented = true
        try? await NauclioTaskSleep.milliseconds(700)
        if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) {
            capture(sheet, to: output.appending(path: "12-board-label-editor.png"))
            results["12-board-label-editor"] = "passed"
        } else {
            results["12-board-label-editor"] = "failed: sheet not visible"
        }
        store.labelsPresented = false
        try? await NauclioTaskSleep.milliseconds(350)

        let connectedPhase = store.phase
        store.phase = .authenticationRequired
        try? await NauclioTaskSleep.milliseconds(700)
        capture(window, to: output.appending(path: "12b-connection-onboarding.png"))
        results["12b-connection-onboarding"] = store.phase.needsConnectionOverlay ? "passed" : "failed: overlay phase inactive"
        store.phase = connectedPhase
        try? await NauclioTaskSleep.milliseconds(350)

        store.createConversationPresented = true
        try? await NauclioTaskSleep.milliseconds(700)
        if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) {
            capture(sheet, to: output.appending(path: "13-new-card.png"))
            results["13-new-card"] = "passed"
        } else {
            results["13-new-card"] = "failed: sheet not visible"
        }
        store.createConversationPresented = false
        try? await NauclioTaskSleep.milliseconds(350)

        store.createProjectPresented = true
        try? await NauclioTaskSleep.milliseconds(700)
        if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) {
            capture(sheet, to: output.appending(path: "14-new-project.png"))
            results["14-new-project"] = "passed"
            click(window: sheet, x: 605, distanceFromTop: 242)
            try? await NauclioTaskSleep.seconds(1.5)
            if let browser = NSApp.windows.first(where: {
                $0.isSheet && $0.isVisible && $0.windowNumber != sheet.windowNumber
            }) {
                capture(browser, to: output.appending(path: "15-remote-directory-browser.png"))
                results["15-remote-directory-browser"] = "passed"
            } else {
                results["15-remote-directory-browser"] = "failed: browser sheet not visible"
            }
        } else {
            results["14-new-project"] = "failed: sheet not visible"
        }
        store.createProjectPresented = false

        writeReport(results, to: output)
    }

    private static func outputDirectory() -> URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--ui-smoke-output"), arguments.indices.contains(index + 1) {
            return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        }
        return URL(filePath: NSTemporaryDirectory()).appending(path: "nauclio-mac-ui-smoke", directoryHint: .isDirectory)
    }

    private static func click(window: NSWindow, x: CGFloat, distanceFromTop: CGFloat) {
        guard let content = window.contentView else { return }
        let location = NSPoint(x: x, y: content.bounds.height - distanceFromTop)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let types: [NSEvent.EventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp]
        for type in types {
            let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: type == .mouseMoved ? 0 : 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )
            if let event { window.sendEvent(event) }
        }
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func writeReport(_ values: [String: String], to directory: URL) {
        let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: directory.appending(path: "report.json"), options: .atomic)
    }
}
