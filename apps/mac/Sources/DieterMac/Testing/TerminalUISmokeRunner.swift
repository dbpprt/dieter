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
    private static let firstMarker = "DIETER_TERMINAL_BEFORE_CLIENT_EXIT"
    private static let secondMarker = "DIETER_TERMINAL_AFTER_CLIENT_RESTART"
    private static let followMarker = "DIETER_TERMINAL_CURSOR_FOLLOW"
    private static let resizeMarker = "DIETER_TERMINAL_AFTER_WINDOW_RESIZE"

    static func run(store: DieterStore) async {
        let output = outputDirectory()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let phase = argument(after: "--terminal-ui-smoke") ?? "create"
        progress("\(phase) runner started; connection phase is \(store.phase.label)", in: output)

        guard await waitUntil(timeout: 45, condition: { store.phase.isConnected }) else {
            writeReport(["connection": "failed: gateway connection did not become ready"], named: reportName(for: phase), to: output)
            return
        }
        guard let window = await appWindow() else {
            writeReport(["window": "failed: Dieter window not found"], named: reportName(for: phase), to: output)
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

    private static func create(store: DieterStore, window: NSWindow, output: URL) async {
        await store.openTerminals()
        guard await waitUntil(timeout: 15, condition: {
            store.projects.contains { store.projectEndpointIDs[$0.id] == store.endpoint.id }
        }),
              let project = store.projects.first(where: {
                  store.projectEndpointIDs[$0.id] == store.endpoint.id
              }) else {
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
        try? await DieterTaskSleep.milliseconds(500)
        capture(window, to: output.appending(path: "01-before-client-exit.png"))

        store.sendTerminalInput(id: terminalID, data: scrollbackCommand())
        let filledScrollback = await waitUntil(timeout: 20, condition: {
            screen(store, terminalID).contains(followMarker)
        })
        try? await DieterTaskSleep.milliseconds(500)
        let presentation = terminalPresentation(in: window)
        capture(window, to: output.appending(path: "01-cursor-follow.png"))

        let initialGrid = terminalGrid(in: window)
        window.setContentSize(NSSize(width: 920, height: 620))
        let shrank = await waitUntil(timeout: 10, condition: {
            guard let grid = terminalGrid(in: window), let initialGrid else { return false }
            return grid.columns < initialGrid.columns
                && store.selectedTerminal.map { Int($0.columns) == grid.columns && Int($0.rows) == grid.rows } == true
        })
        store.sendTerminalInput(id: terminalID, data: command(printing: resizeMarker))
        let resizedOutput = await waitUntil(timeout: 20, condition: {
            terminalVisibleText(in: window).contains(resizeMarker)
        })
        try? await DieterTaskSleep.milliseconds(500)
        let narrowPresentation = terminalPresentation(in: window)
        capture(window, to: output.appending(path: "01-after-window-shrink.png"))

        let narrowGrid = terminalGrid(in: window)
        window.setContentSize(NSSize(width: 1_500, height: 900))
        let expanded = await waitUntil(timeout: 10, condition: {
            guard let grid = terminalGrid(in: window), let narrowGrid else { return false }
            return grid.columns > narrowGrid.columns
                && store.selectedTerminal.map { Int($0.columns) == grid.columns && Int($0.rows) == grid.rows } == true
        })
        try? await DieterTaskSleep.milliseconds(500)
        capture(window, to: output.appending(path: "01-after-window-expand.png"))

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
            "window-shrink-grid": shrank
                ? "passed"
                : "failed: shrinking the AppKit window did not resize both emulator and PTY grids",
            "window-expand-grid": expanded
                ? "passed"
                : "failed: expanding the AppKit window did not resize both emulator and PTY grids",
            "resize-output": resizedOutput
                ? "passed"
                : "failed: output after a window resize was not rendered in the visible emulator",
            "resize-cursor-tracking": narrowPresentation.cursorTracks
                ? "passed"
                : "failed: the caret left the resized terminal bounds",
            "terminal-running": store.selectedTerminal?.status == "running" ? "passed" : "failed: terminal was not running",
        ], named: "create-report.json", to: output)
    }

    private static func resume(store: DieterStore, window: NSWindow, output: URL) async {
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
        let rendered = await waitUntil(timeout: 20, condition: {
            terminalVisibleText(in: window).contains(secondMarker)
        })
        try? await DieterTaskSleep.seconds(1)
        let restartPresentation = terminalPresentation(in: window)
        let restartGrid = terminalGrid(in: window)
        let remoteGrid = store.terminals.first(where: { $0.id == terminalID }).map {
            (columns: Int($0.columns), rows: Int($0.rows))
        }
        capture(window, to: output.appending(path: "02-after-client-restart.png"))

        writeReport([
            "connection": "passed",
            "created-by-first-app": create["terminal-create"] ?? "failed: missing create result",
            "initial-output": create["initial-output"] ?? "failed: missing output result",
            "listed-after-restart": listed ? "passed" : "failed: daemon-owned terminal was not listed",
            "scrollback-replayed": replayed ? "passed" : "failed: pre-disconnect output was not replayed",
            "input-after-restart": continued ? "passed" : "failed: resumed terminal did not accept input",
            "rendered-after-restart": rendered
                ? "passed"
                : "failed: resumed output reached the store but not the visible emulator",
            "restart-grid": restartGrid != nil && restartGrid?.columns == remoteGrid?.columns && restartGrid?.rows == remoteGrid?.rows
                ? "passed"
                : "failed: the resumed emulator and persisted PTY geometry diverged",
            "restart-cursor-tracking": restartPresentation.cursorTracks
                ? "passed"
                : "failed: the resumed caret did not track the emulator cursor",
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
            "i=1; while [ \"$i\" -le 80 ]; do printf 'DIETER_FOLLOW_%03d\\n' \"$i\"; i=$((i+1)); done; printf '%s\\n' '\(followMarker)'\n".utf8
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

    private static func terminalGrid(in window: NSWindow) -> (columns: Int, rows: Int)? {
        guard let view = terminalView(in: window.contentView) else { return nil }
        return (view.terminal.cols, view.terminal.rows)
    }

    private static func terminalVisibleText(in window: NSWindow) -> String {
        guard let view = terminalView(in: window.contentView) else { return "" }
        return (0..<view.terminal.rows)
            .compactMap { view.terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    private static func terminalView(in root: NSView?) -> SwiftTerm.TerminalView? {
        guard let root else { return nil }
        if let terminal = root as? SwiftTerm.TerminalView { return terminal }
        for child in root.subviews {
            if let terminal = terminalView(in: child) { return terminal }
        }
        return nil
    }

    private static func screen(_ store: DieterStore, _ terminalID: String) -> String {
        String(decoding: store.terminalScreens[terminalID]?.data ?? Data(), as: UTF8.self)
    }

    private static func waitUntil(timeout: Int, condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<(timeout * 10) {
            if condition() { return true }
            try? await DieterTaskSleep.milliseconds(100)
        }
        return condition()
    }

    private static func appWindow() async -> NSWindow? {
        for _ in 0..<100 {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Dieter" })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                return window
            }
            try? await DieterTaskSleep.milliseconds(100)
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
        return URL(filePath: NSTemporaryDirectory()).appending(path: "dieter-terminal-ui-smoke", directoryHint: .isDirectory)
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
        // `open -W` waits for the application but terminating that wrapper does
        // not terminate a separately launched `-n` app instance. End each
        // smoke phase from inside the app so restart coverage always uses one
        // clean client process at a time.
        DispatchQueue.main.async { NSApp.terminate(nil) }
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
