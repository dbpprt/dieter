import AppKit
import Foundation
import SwiftTerm

/// Drives the persistent-terminal flow from inside the packaged Mac app.
///
/// The shell is created in one app process and resumed by a second one. The
/// shell and its scrollback therefore have to survive a real client disconnect,
/// not merely a view transition.
@MainActor
enum TerminalUISmokeRunner {
    private static let firstMarker = "NAUCLIO_TERMINAL_BEFORE_CLIENT_EXIT"
    private static let secondMarker = "NAUCLIO_TERMINAL_AFTER_CLIENT_RESTART"
    private static let followMarker = "NAUCLIO_TERMINAL_CURSOR_FOLLOW"

    static func run(store: NauclioStore) async {
        let output = outputDirectory()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let phase = argument(after: "--terminal-ui-smoke") ?? "create"
        progress("\(phase) runner started; connection phase is \(store.phase.label)", in: output)

        guard await waitUntil(timeout: 45, condition: { store.phase.isConnected }) else {
            writeReport(["connection": "failed: gateway connection did not become ready"], named: reportName(for: phase), to: output)
            return
        }
        guard let window = await appWindow() else {
            writeReport(["window": "failed: Nauclio window not found"], named: reportName(for: phase), to: output)
            return
        }
        window.setContentSize(NSSize(width: 1_380, height: 870))
        window.center()
        window.makeKeyAndOrderFront(nil)

        switch phase {
        case "create":
            await create(store: store, window: window, output: output)
        case "resume":
            await resume(store: store, window: window, output: output)
        default:
            writeReport(["phase": "failed: unknown terminal smoke phase \(phase)"], named: reportName(for: phase), to: output)
        }
    }

    private static func create(store: NauclioStore, window: NSWindow, output: URL) async {
        await store.openTerminals()
        guard await waitUntil(timeout: 15, condition: { !store.projects.isEmpty }),
              let project = store.projects.first else {
            writeReport(["project": "failed: isolated project was not loaded"], named: "create-report.json", to: output)
            return
        }

        let originalIDs = Set(store.terminals.map(\.id))
        await store.createTerminal(
            projectID: project.id,
            name: "persistent-e2e",
            shell: "sh",
            workingDirectory: project.path
        )
        guard await waitUntil(timeout: 15, condition: {
            guard let id = store.selectedTerminalID else { return false }
            return !originalIDs.contains(id) && store.terminals.contains(where: { $0.id == id })
        }), let terminalID = store.selectedTerminalID else {
            writeReport(["terminal-create": "failed: terminal was not created"], named: "create-report.json", to: output)
            return
        }

        store.sendTerminalInput(id: terminalID, data: command(printing: firstMarker))
        let received = await waitUntil(timeout: 20, condition: { screen(store, terminalID).contains(firstMarker) })
        try? await NauclioTaskSleep.milliseconds(500)
        capture(window, to: output.appending(path: "01-before-client-exit.png"))

        store.sendTerminalInput(id: terminalID, data: scrollbackCommand())
        let filledScrollback = await waitUntil(timeout: 20, condition: {
            screen(store, terminalID).contains(followMarker)
        })
        try? await NauclioTaskSleep.milliseconds(500)
        let presentation = terminalPresentation(in: window)
        capture(window, to: output.appending(path: "01-cursor-follow.png"))

        writeReport([
            "connection": "passed",
            "terminal-id": terminalID,
            "terminal-create": "passed",
            "initial-output": received ? "passed" : "failed: first marker was not rendered",
            "scrollback-output": filledScrollback ? "passed" : "failed: scrollback marker was not rendered",
            "cursor-tracking": presentation.cursorTracks
                ? "passed"
                : "failed: SwiftTerm caret did not track the emulator cursor",
            "viewport-follow": presentation.viewportFollows
                ? "passed"
                : "failed: live output did not keep the terminal viewport at the cursor",
            "terminal-running": store.selectedTerminal?.status == "running" ? "passed" : "failed: terminal was not running",
        ], named: "create-report.json", to: output)
    }

    private static func resume(store: NauclioStore, window: NSWindow, output: URL) async {
        guard let create = readReport(named: "create-report.json", from: output),
              let terminalID = create["terminal-id"], !terminalID.isEmpty else {
            writeReport(["create-report": "failed: terminal id is missing"], named: "report.json", to: output)
            return
        }

        await store.openTerminals()
        if store.terminals.contains(where: { $0.id == terminalID }) {
            store.selectTerminal(terminalID)
        }
        let listed = await waitUntil(timeout: 20, condition: {
            store.terminals.contains(where: { $0.id == terminalID && $0.status == "running" })
        })
        let replayed = await waitUntil(timeout: 20, condition: { screen(store, terminalID).contains(firstMarker) })

        store.sendTerminalInput(id: terminalID, data: command(printing: secondMarker))
        let continued = await waitUntil(timeout: 20, condition: { screen(store, terminalID).contains(secondMarker) })
        try? await NauclioTaskSleep.seconds(1)
        capture(window, to: output.appending(path: "02-after-client-restart.png"))

        writeReport([
            "connection": "passed",
            "created-by-first-app": create["terminal-create"] ?? "failed: missing create result",
            "initial-output": create["initial-output"] ?? "failed: missing output result",
            "listed-after-restart": listed ? "passed" : "failed: daemon-owned terminal was not listed",
            "scrollback-replayed": replayed ? "passed" : "failed: pre-disconnect output was not replayed",
            "input-after-restart": continued ? "passed" : "failed: resumed terminal did not accept input",
            "terminal-running": store.terminals.first(where: { $0.id == terminalID })?.status == "running"
                ? "passed"
                : "failed: terminal was not running after restart",
            "gateway": store.endpoint.address,
        ], named: "report.json", to: output)
    }

    private static func command(printing marker: String) -> Data {
        Data("printf '\\033[1;36m%s\\033[0m\\n' '\(marker)'\n".utf8)
    }

    private static func scrollbackCommand() -> Data {
        Data(
            "i=1; while [ \"$i\" -le 80 ]; do printf 'NAUCLIO_FOLLOW_%03d\\n' \"$i\"; i=$((i+1)); done; printf '%s\\n' '\(followMarker)'\n".utf8
        )
    }

    private static func terminalPresentation(in window: NSWindow) -> (cursorTracks: Bool, viewportFollows: Bool) {
        guard let view = terminalView(in: window.contentView) else { return (false, false) }
        let caret = view.caretFrame
        let cursor = view.terminal.getCursorLocation()
        let expectedX = CGFloat(cursor.x) * caret.width
        let caretTracks = caret.width > 0
            && abs(caret.minX - expectedX) < 1.5
            && view.bounds.intersects(caret)
        return (
            cursorTracks: caretTracks,
            viewportFollows: caretTracks && view.terminal.getTopVisibleRow() > 0
        )
    }

    private static func terminalView(in root: NSView?) -> SwiftTerm.TerminalView? {
        guard let root else { return nil }
        if let terminal = root as? SwiftTerm.TerminalView { return terminal }
        for child in root.subviews {
            if let terminal = terminalView(in: child) { return terminal }
        }
        return nil
    }

    private static func screen(_ store: NauclioStore, _ terminalID: String) -> String {
        String(decoding: store.terminalScreens[terminalID]?.data ?? Data(), as: UTF8.self)
    }

    private static func waitUntil(timeout: Int, condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<(timeout * 10) {
            if condition() { return true }
            try? await NauclioTaskSleep.milliseconds(100)
        }
        return condition()
    }

    private static func appWindow() async -> NSWindow? {
        for _ in 0..<100 {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Nauclio" })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                return window
            }
            try? await NauclioTaskSleep.milliseconds(100)
        }
        return nil
    }

    private static func argument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func outputDirectory() -> URL {
        if let value = argument(after: "--ui-smoke-output") {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
        return URL(filePath: NSTemporaryDirectory()).appending(path: "nauclio-terminal-ui-smoke", directoryHint: .isDirectory)
    }

    private static func reportName(for phase: String) -> String {
        phase == "create" ? "create-report.json" : "report.json"
    }

    private static func readReport(named name: String, from directory: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: directory.appending(path: name)),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return value
    }

    private static func writeReport(_ values: [String: String], named name: String, to directory: URL) {
        let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: directory.appending(path: name), options: .atomic)
    }

    private static func progress(_ message: String, in directory: URL) {
        let line = "\(Date()) \(message)\n"
        let url = directory.appending(path: "progress.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
