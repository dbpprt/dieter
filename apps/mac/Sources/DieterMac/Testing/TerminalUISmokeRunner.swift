#if DIETER_UI_SMOKE
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
        private static let pasteMarker = "DIETER_TERMINAL_CLIPBOARD_PASTE"
        private static let deleteMarker = "DIETER_TERMINAL_DELETE_KEY"
        private static let editReadyMarker = "DIETER_TERMINAL_EDIT_READY"

        static func run(store: DieterStore) async {
            let output = outputDirectory()
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let phase = argument(after: "--terminal-ui-smoke") ?? "create"
            progress("\(phase) runner started; connection phase is \(store.phase.label)", in: output)

            guard await waitUntil(timeout: 45, condition: { store.phase.isConnected }) else {
                writeReport(
                    ["connection": "failed: gateway connection did not become ready"], named: reportName(for: phase),
                    to: output)
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
                writeReport(
                    ["phase": "failed: unknown terminal smoke phase \(phase)"], named: reportName(for: phase),
                    to: output)
            }
        }

        private static func create(store: DieterStore, window: NSWindow, output: URL) async {
            await store.openTerminals()
            let originalEndpointID = store.endpoint.id
            guard
                await waitUntil(
                    timeout: 15,
                    condition: {
                        store.endpoints.contains {
                            $0.id != store.endpoint.id && $0.online && $0.apiCompatibility == .compatible
                        }
                    }),
                let destination = store.endpoints.first(where: {
                    $0.id != store.endpoint.id && $0.online && $0.apiCompatibility == .compatible
                })
            else {
                writeReport(
                    ["machine-switch": "failed: second compatible machine was not discovered"],
                    named: "create-report.json", to: output)
                return
            }
            await store.openTerminals(on: destination)
            guard store.endpoint.id == originalEndpointID, store.phase.isConnected else {
                writeReport(
                    ["overview-routing": "failed: opening a machine changed the app's active workspace connection"],
                    named: "create-report.json", to: output)
                return
            }

            store.createTerminalPresented = true
            let sheetPresented = await waitUntil(timeout: 10, condition: { window.attachedSheet != nil })
            let sheetSize = window.attachedSheet?.contentView?.bounds.size
            var projectPickerWorks = false
            if let sheet = window.attachedSheet {
                projectPickerWorks =
                    NativeUIAccessibility.find("new-terminal.project", in: sheet)?.recordedFrame?.isEmpty == false
                let defaults = DieterAppearance.applicationDefaults()
                let originalAppearance = defaults.string(forKey: DieterAppearance.storageKey)
                for appearance in [DieterAppearance.dark, DieterAppearance.light] {
                    defaults.set(appearance.rawValue, forKey: DieterAppearance.storageKey)
                    try? await DieterTaskSleep.milliseconds(450)
                    capture(sheet, to: output.appending(path: "00-new-terminal-sheet-\(appearance.rawValue).png"))
                }
                if let originalAppearance {
                    defaults.set(originalAppearance, forKey: DieterAppearance.storageKey)
                } else {
                    defaults.removeObject(forKey: DieterAppearance.storageKey)
                }
                try? await DieterTaskSleep.milliseconds(300)
            }
            let sheetIsCompact =
                sheetSize.map { size in
                    size.width >= 480 && size.width <= 560 && size.height >= 400 && size.height <= 520
                } ?? false
            store.createTerminalPresented = false
            _ = await waitUntil(timeout: 10, condition: { window.attachedSheet == nil })

            let originalIDs = Set(store.terminalOverviewEntries.map(\.id))
            await store.createTerminal(
                projectID: "",
                machineID: destination.id,
                machineHome: true,
                name: "persistent-e2e",
                shell: "sh",
                workingDirectory: "~"
            )
            guard
                await waitUntil(
                    timeout: 15,
                    condition: {
                        guard let id = store.selectedTerminalOverviewID else { return false }
                        return !originalIDs.contains(id)
                            && store.terminalOverviewEntries.contains(where: {
                                $0.id == id && $0.machineID == destination.id
                            })
                    }), let selectedOverviewID = store.selectedTerminalOverviewID,
                let selectedEntry = store.terminalOverviewEntries.first(where: { $0.id == selectedOverviewID })
            else {
                writeReport(
                    ["terminal-create": "failed: terminal was not created"], named: "create-report.json", to: output)
                return
            }
            let terminalID = selectedEntry.terminal.id
            let nodeBadgeMounted = await waitUntil(
                timeout: 5,
                condition: {
                    NativeUIAccessibility.find("terminal.node.\(destination.id).\(terminalID)", in: window)?
                        .recordedFrame?.isEmpty == false
                })

            store.sendTerminalInput(id: terminalID, data: command(printing: firstMarker))
            let received = await waitUntil(timeout: 20, condition: { screen(store, terminalID).contains(firstMarker) })
            try? await DieterTaskSleep.milliseconds(500)
            let clipboard = await terminalClipboardInteraction(store: store, terminalID: terminalID, in: window)
            let editingKeys = await terminalEditingKeysInteraction(store: store, terminalID: terminalID, in: window)
            capture(window, to: output.appending(path: "01-selection-copy-paste.png"))
            capture(window, to: output.appending(path: "01-before-client-exit.png"))

            store.sendTerminalInput(id: terminalID, data: scrollbackCommand())
            let filledScrollback = await waitUntil(
                timeout: 20,
                condition: {
                    screen(store, terminalID).contains(followMarker)
                })
            try? await DieterTaskSleep.milliseconds(500)
            let presentation = terminalPresentation(in: window)
            capture(window, to: output.appending(path: "01-cursor-follow.png"))

            let initialGrid = terminalGrid(in: window)
            window.setContentSize(NSSize(width: 920, height: 620))
            let shrank = await waitUntil(
                timeout: 10,
                condition: {
                    guard let grid = terminalGrid(in: window), let initialGrid else { return false }
                    return grid.columns < initialGrid.columns
                        && store.selectedTerminal.map { Int($0.columns) == grid.columns && Int($0.rows) == grid.rows }
                            == true
                })
            store.sendTerminalInput(id: terminalID, data: command(printing: resizeMarker))
            let resizedOutput = await waitUntil(
                timeout: 20,
                condition: {
                    terminalVisibleText(in: window).contains(resizeMarker)
                })
            try? await DieterTaskSleep.milliseconds(500)
            let narrowPresentation = terminalPresentation(in: window)
            capture(window, to: output.appending(path: "01-after-window-shrink.png"))

            let narrowGrid = terminalGrid(in: window)
            window.setContentSize(NSSize(width: 1_500, height: 900))
            let expanded = await waitUntil(
                timeout: 10,
                condition: {
                    guard let grid = terminalGrid(in: window), let narrowGrid else { return false }
                    return grid.columns > narrowGrid.columns
                        && store.selectedTerminal.map { Int($0.columns) == grid.columns && Int($0.rows) == grid.rows }
                            == true
                })
            try? await DieterTaskSleep.milliseconds(500)
            capture(window, to: output.appending(path: "01-after-window-expand.png"))

            writeReport(
                [
                    "connection": "passed",
                    "terminal-id": terminalID,
                    "machine-id": destination.id,
                    "active-machine-id": originalEndpointID,
                    "overview-routing": "passed",
                    "terminal-create": "passed",
                    "machine-home-scope": store.selectedTerminal?.projectID.isEmpty == true
                        ? "passed" : "failed: terminal unexpectedly required a project",
                    "new-terminal-sheet": sheetPresented
                        ? (sheetIsCompact ? "passed" : "failed: terminal sheet escaped its compact layout bounds")
                        : "failed: terminal sheet was not presented",
                    "project-picker": projectPickerWorks
                        ? "passed" : "failed: native project picker did not occupy visible layout",
                    "terminal-node-badge": nodeBadgeMounted
                        ? "passed" : "failed: selected terminal tab did not show its machine badge",
                    "initial-output": received ? "passed" : "failed: first marker was not rendered",
                    "terminal-text-selection": clipboard.selection
                        ? "passed" : "failed: a single native drag did not select terminal text",
                    "terminal-copy": clipboard.copy
                        ? "passed" : "failed: Command-C did not copy the selected terminal text",
                    "terminal-paste": clipboard.paste
                        ? "passed" : "failed: Command-V did not reach the remote PTY",
                    "terminal-context-menu": clipboard.contextMenu
                        ? "passed" : "failed: native terminal edit actions were missing",
                    "terminal-delete-key": editingKeys
                        ? "passed" : "failed: Backspace did not edit the shell input line",
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
                    "terminal-running": store.selectedTerminal?.status == "running"
                        ? "passed" : "failed: terminal was not running",
                ], named: "create-report.json", to: output)
        }

        private static func resume(store: DieterStore, window: NSWindow, output: URL) async {
            guard let create = readReport(named: "create-report.json", from: output),
                let terminalID = create["terminal-id"], !terminalID.isEmpty
            else {
                writeReport(["create-report": "failed: terminal id is missing"], named: "report.json", to: output)
                return
            }

            await store.openTerminals()
            guard let machineID = create["machine-id"],
                await waitUntil(timeout: 15, condition: { store.endpoints.contains(where: { $0.id == machineID }) }),
                let machine = store.endpoints.first(where: { $0.id == machineID })
            else {
                writeReport(
                    ["machine-restore": "failed: created terminal machine was not rediscovered"],
                    named: "report.json", to: output)
                return
            }
            await store.loadTerminalOverview(preferredMachineID: machine.id)
            let overviewID = TerminalOverviewEntry.id(machineID: machineID, terminalID: terminalID)
            if store.terminalOverviewEntries.contains(where: { $0.id == overviewID }) {
                await store.selectTerminalOverviewEntry(overviewID)
            }
            let machineRestored = await waitUntil(timeout: 10) {
                store.selectedTerminalOverviewID == overviewID
                    && store.terminalsModel.target.endpointID == machineID
                    && store.endpoint.id == create["active-machine-id"]
            }
            let routingDetail =
                "selection=\(store.selectedTerminalOverviewID ?? "none") expected=\(overviewID), target=\(store.terminalsModel.target.endpointID) expected=\(machineID), active=\(store.endpoint.id) expected=\(create["active-machine-id"] ?? "none")"
            let listed = await waitUntil(
                timeout: 20,
                condition: {
                    store.terminalOverviewEntries.contains(where: {
                        $0.id == overviewID && $0.terminal.status == "running"
                    })
                })
            let replayed = await waitUntil(timeout: 20, condition: { screen(store, terminalID).contains(firstMarker) })

            store.sendTerminalInput(id: terminalID, data: command(printing: secondMarker))
            let continued = await waitUntil(
                timeout: 20, condition: { screen(store, terminalID).contains(secondMarker) })
            let rendered = await waitUntil(
                timeout: 20,
                condition: {
                    terminalVisibleText(in: window).contains(secondMarker)
                })
            try? await DieterTaskSleep.seconds(1)
            let restartPresentation = terminalPresentation(in: window)
            let restartGrid = terminalGrid(in: window)
            let remoteGrid = store.terminals.first(where: { $0.id == terminalID }).map {
                (columns: Int($0.columns), rows: Int($0.rows))
            }
            capture(window, to: output.appending(path: "02-after-client-restart.png"))
            let stayedRunning =
                store.terminalOverviewEntries.first(where: { $0.id == overviewID })?.terminal.status
                == "running"
            await store.closeTerminalOverviewEntry(overviewID)
            let cleanedUp = await waitUntil(
                timeout: 10,
                condition: { !store.terminalOverviewEntries.contains(where: { $0.id == overviewID }) })

            writeReport(
                [
                    "connection": "passed",
                    "created-by-first-app": create["terminal-create"] ?? "failed: missing create result",
                    "initial-output": create["initial-output"] ?? "failed: missing output result",
                    "listed-after-restart": listed ? "passed" : "failed: daemon-owned terminal was not listed",
                    "machine-restore": machineRestored
                        ? "passed"
                        : "failed: aggregate terminal routing was not restored independently; \(routingDetail)",
                    "scrollback-replayed": replayed ? "passed" : "failed: pre-disconnect output was not replayed",
                    "input-after-restart": continued ? "passed" : "failed: resumed terminal did not accept input",
                    "rendered-after-restart": rendered
                        ? "passed"
                        : "failed: resumed output reached the store but not the visible emulator",
                    "restart-grid": restartGrid != nil && restartGrid?.columns == remoteGrid?.columns
                        && restartGrid?.rows == remoteGrid?.rows
                        ? "passed"
                        : "failed: the resumed emulator and persisted PTY geometry diverged",
                    "restart-cursor-tracking": restartPresentation.cursorTracks
                        ? "passed"
                        : "failed: the resumed caret did not track the emulator cursor",
                    "terminal-running": stayedRunning
                        ? "passed"
                        : "failed: terminal was not running after restart",
                    "terminal-cleanup": cleanedUp
                        ? "passed" : "failed: persistent terminal was not closed after the smoke run",
                    "gateway": store.endpoint.address,
                ], named: "report.json", to: output)
        }

        private static func command(printing marker: String) -> Data {
            Data("printf '\\033[1;36m%s\\033[0m\\n' '\(marker)'\n".utf8)
        }

        private static func scrollbackCommand() -> Data {
            Data(
                "i=1; while [ \"$i\" -le 80 ]; do printf 'DIETER_FOLLOW_%03d\\n' \"$i\"; i=$((i+1)); done; printf '%s\\n' '\(followMarker)'\n"
                    .utf8
            )
        }

        private static func terminalClipboardInteraction(
            store: DieterStore,
            terminalID: String,
            in window: NSWindow
        ) async -> (selection: Bool, copy: Bool, paste: Bool, contextMenu: Bool) {
            guard let view = terminalView(in: window.contentView) as? RemoteTerminalView else {
                return (false, false, false, false)
            }

            let pasteboard = NSPasteboard.general
            let savedItems =
                pasteboard.pasteboardItems?.map { source in
                    source.types.compactMap { type in
                        source.data(forType: type).map { (type.rawValue, $0) }
                    }
                } ?? []
            defer {
                pasteboard.clearContents()
                let restoredItems = savedItems.map { contents in
                    let item = NSPasteboardItem()
                    for (type, data) in contents {
                        item.setData(data, forType: NSPasteboard.PasteboardType(type))
                    }
                    return item
                }
                if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
            }

            _ = window.makeFirstResponder(nil)
            let cell = view.caretFrame.size
            let cursor = view.terminal.getCursorLocation()
            let selectedRow = max(0, cursor.y - 1)
            let y = view.bounds.height - (CGFloat(selectedRow) + 0.5) * cell.height
            view.mouseDown(
                with: mouseEvent(.leftMouseDown, point: NSPoint(x: cell.width / 2, y: y), view: view))
            view.mouseDragged(
                with: mouseEvent(.leftMouseDragged, point: NSPoint(x: cell.width * 48.5, y: y), view: view))
            view.mouseUp(
                with: mouseEvent(.leftMouseUp, point: NSPoint(x: cell.width * 48.5, y: y), view: view))
            let selected = window.firstResponder === view && view.selectedRange().length > 0

            pasteboard.clearContents()
            NSApp.sendEvent(keyEvent("c", keyCode: 8, modifiers: .command, window: window))
            let copied = pasteboard.string(forType: .string)?.contains(firstMarker) == true
            let menuTitles =
                view.menu(
                    for: mouseEvent(.rightMouseDown, point: NSPoint(x: cell.width, y: y), view: view))?
                .items.map(\.title).filter { !$0.isEmpty } ?? []

            pasteboard.clearContents()
            pasteboard.setString(String(decoding: command(printing: pasteMarker), as: UTF8.self), forType: .string)
            NSApp.sendEvent(keyEvent("v", keyCode: 9, modifiers: .command, window: window))
            let pasted = await waitUntil(timeout: 20) { screen(store, terminalID).contains(pasteMarker) }
            return (selected, copied, pasted, menuTitles == ["Copy", "Paste", "Select All"])
        }

        private static func terminalEditingKeysInteraction(
            store: DieterStore,
            terminalID: String,
            in window: NSWindow
        ) async -> Bool {
            guard let view = terminalView(in: window.contentView) as? RemoteTerminalView else { return false }

            // Disable shell echo so the marker can only appear when the edited
            // command actually executes, not merely because its source was drawn.
            store.sendTerminalInput(
                id: terminalID,
                data: Data("stty -echo; printf '%s\\n' '\(editReadyMarker)'\n".utf8))
            guard
                await waitUntil(
                    timeout: 20,
                    condition: {
                        screen(store, terminalID).contains("\(editReadyMarker)\r\n")
                    })
            else { return false }
            window.makeFirstResponder(view)
            view.insertText(
                "printf '%s\\n' \(deleteMarker)x",
                replacementRange: NSRange(location: NSNotFound, length: 0))
            NSApp.sendEvent(keyEvent("\u{7f}", keyCode: 51, window: window))
            NSApp.sendEvent(keyEvent("\r", keyCode: 36, window: window))
            let edited = await waitUntil(timeout: 20) {
                screen(store, terminalID).contains("\(deleteMarker)\r\n")
            }
            store.sendTerminalInput(id: terminalID, data: Data("stty echo\n".utf8))
            return edited
        }

        private static func mouseEvent(
            _ type: NSEvent.EventType,
            point: NSPoint,
            modifiers: NSEvent.ModifierFlags = [],
            view: NSView
        ) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: view.convert(point, to: nil),
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )!
        }

        private static func keyEvent(
            _ characters: String,
            keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags = [],
            window: NSWindow
        ) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )!
        }

        private static func terminalPresentation(in window: NSWindow) -> (cursorTracks: Bool, viewportFollows: Bool) {
            guard let view = terminalView(in: window.contentView) else { return (false, false) }
            let caret = view.caretFrame
            let cursor = view.terminal.getCursorLocation()
            let expectedX = CGFloat(cursor.x) * caret.width
            let caretTracks =
                caret.width > 0
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
                if let window = NSApp.windows.first(where: {
                    $0.isVisible && $0.contentView != nil && $0.title == "Dieter"
                })
                    ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
                {
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
            return URL(filePath: NSTemporaryDirectory()).appending(
                path: "dieter-terminal-ui-smoke", directoryHint: .isDirectory)
        }

        private static func reportName(for phase: String) -> String {
            phase == "create" ? "create-report.json" : "report.json"
        }

        private static func readReport(named name: String, from directory: URL) -> [String: String]? {
            guard let data = try? Data(contentsOf: directory.appending(path: name)),
                let value = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return nil }
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
                let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
#endif
