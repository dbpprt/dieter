#if DIETER_UI_SMOKE
    import AppKit
    import DieterAPI
    import Foundation
    import PDFKit

    @MainActor enum ConversationFileActionsUISmoke {
        static var configureSavePanel: ((NSSavePanel, NSWindow?) -> Void)?

        static func exportUnsavedDraft(
            store: DieterStore, tab: ConversationContentTab, window: NSWindow,
            results: inout [String: String], output: URL
        ) async {
            let draft = tab.files.fileEditorSession.currentText()
            let saved = tab.files.fileDocument?.content
            let marker = "Implementation reviewed in the content pane."
            guard tab.dirty, draft.contains(marker), saved?.contains(marker) == false else {
                results["content-export-unsaved-fixture"] = "failed: export requires a distinguishable unsaved draft"
                return
            }
            let directory = output.appending(path: "document-exports", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for format in MarkdownFileExport.Format.allCases {
                let trace = NativeExportSmokeTrace(output: output, format: format)
                defer { persistExportResults(results, output: output) }
                var configured = false
                var configuredPanel: NSSavePanel?
                configureSavePanel = { panel, owner in
                    trace.record("configuration callback", panel: panel, owner: owner)
                    guard owner === window, panel.title == format.title else { return }
                    // The Save panel accepts directory/name configuration only
                    // before presentation. Preserve the app's suggested name.
                    panel.directoryURL = directory
                    configured = true
                    configuredPanel = panel
                    trace.record("configured destination", panel: panel, owner: owner)
                }
                defer { configureSavePanel = nil }
                let tracker = NativeContentMenuTracker()
                defer { tracker.stop() }
                let clicked = NativeUIAccessibility.click(
                    "conversation.content.file.\(tab.id.uuidString).export-menu", in: window)
                trace.record("clicked menu: \(clicked)")
                let opened = await NativeUIAccessibility.wait(timeout: 5) {
                    tracker.menu?.items.contains(where: { $0.title == "\(format.title)…" }) == true
                }
                guard clicked, opened, let menu = tracker.menu,
                    let index = menu.items.firstIndex(where: { $0.title == "\(format.title)…" })
                else {
                    tracker.menu?.cancelTrackingWithoutAnimation()
                    results["content-export-\(format.rawValue)"] = "failed: native Export menu item unavailable"
                    continue
                }
                // Invoke the actual native menu item's action, as accessibility
                // does. The action must still present the real Save panel.
                menu.cancelTrackingWithoutAnimation()
                menu.performActionForItem(at: index)
                trace.record("invoked native menu item")
                let panelReady = await NativeUIAccessibility.wait(timeout: 5) {
                    guard let panel = configuredPanel else { return false }
                    return panel.isVisible && (panel.sheetParent === window || window.attachedSheet === panel)
                }
                guard panelReady, let panel = configuredPanel else {
                    trace.record(
                        "panel missing: configured=\(configured)", panel: savePanel(for: window), owner: window)
                    results["content-export-\(format.rawValue)"] =
                        "failed: native Save panel was not presented; configuration callback matched=\(configured)"
                    continue
                }
                trace.record("panel visible", panel: panel, owner: window)
                let filename = "side-by-side-smoke.\(format.rawValue)"
                let suggestedCorrectly = panel.nameFieldStringValue == filename
                let destination = directory.appending(path: filename)
                let destinationReady = await NativeUIAccessibility.wait(timeout: 5) {
                    configured && panel.isVisible && panel.sheetParent === window
                        && panel.directoryURL?.standardizedFileURL.resolvingSymlinksInPath().path
                            == directory.standardizedFileURL.resolvingSymlinksInPath().path
                        && panel.nameFieldStringValue == filename && panel.prompt == "Export"
                }
                // Modern Save panels host their controls in another process.
                // AppKit intentionally cannot accept them through panel.ok(_:).
                // Send a native event only to this isolated smoke app; capture
                // runs also allow the external UI driver to press the real button.
                trace.record("destination ready: \(destinationReady)", panel: panel, owner: window)
                let submitted = destinationReady && submitNativeReturn(panel: panel, owner: window)
                trace.record("posted native Return: \(submitted)", panel: panel, owner: window)
                var dismissed = await NativeUIAccessibility.wait(timeout: 5) {
                    window.attachedSheet == nil && !panel.isVisible
                }
                if destinationReady, !dismissed {
                    await requestExportCapture(
                        panel: panel, owner: window, format: format, destination: destination,
                        output: output, trace: trace)
                    dismissed = window.attachedSheet == nil && !panel.isVisible
                }
                trace.record("sheet dismissed: \(dismissed)", panel: panel, owner: window)
                if destinationReady, !dismissed,
                    ProcessInfo.processInfo.environment["DIETER_CONTENT_CAPTURE"] != "1"
                {
                    results["content-export-\(format.rawValue)"] =
                        "skipped: native Save sheet and destination verified; export acceptance requires the external UI driver in a capture run"
                    panel.cancel(nil)
                    _ = await NativeUIAccessibility.wait(timeout: 5) { !panel.isVisible && window.attachedSheet == nil }
                    continue
                }
                var written = false
                if dismissed {
                    written = await NativeUIAccessibility.wait(timeout: 30) {
                        FileManager.default.fileExists(atPath: destination.path)
                    }
                }
                trace.record("file written: \(written); error=\(tab.files.fileError ?? "none")")
                var includesDraft = false
                if let data = try? Data(contentsOf: destination) {
                    switch format {
                    case .pdf:
                        if let pdf = PDFDocument(data: data) {
                            let text = pdf.string?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                            includesDraft = pdf.pageCount > 0 && text?.contains(marker) == true
                        }
                    case .html:
                        if let html = String(data: data, encoding: .utf8) {
                            includesDraft = html.contains(marker) && html.contains("<h1") && !html.contains("<script")
                        }
                    }
                }
                let preserved =
                    tab.dirty && tab.files.fileEditorSession.currentText() == draft
                    && tab.files.fileDocument?.content == saved
                results["content-export-\(format.rawValue)"] =
                    suggestedCorrectly && destinationReady && dismissed && written && includesDraft && preserved
                    ? "passed"
                    : "failed: suggested filename=\(suggestedCorrectly), native destination=\(destinationReady), sheet dismissed=\(dismissed), written=\(written), draft included=\(includesDraft), dirty buffer preserved=\(preserved), error=\(tab.files.fileError ?? "none")"
                trace.record(results["content-export-\(format.rawValue)"] ?? "missing result")
                if panel.isVisible { panel.cancel(nil) }
                _ = await NativeUIAccessibility.wait(timeout: 5) {
                    window.attachedSheet == nil && !panel.isVisible
                }
            }
            do {
                guard let rpc = store.rpc else { throw CocoaError(.fileReadUnknown) }
                var request = Dieter_V1_ReadFileRequest()
                request.projectID = tab.files.target.projectID
                request.cardID = tab.files.target.conversationID
                request.path = tab.files.fileDocument?.path ?? ""
                let document = try await rpc.readFile(request)
                results["content-export-keeps-original-unsaved"] =
                    document.content == saved && tab.dirty ? "passed" : "failed: export changed the original file"
            } catch { results["content-export-keeps-original-unsaved"] = "failed: \(error)" }
            persistExportResults(results, output: output)
        }

        private static func persistExportResults(_ results: [String: String], output: URL) {
            let exports = results.filter { $0.key.hasPrefix("content-export-") }
            guard
                let data = try? JSONSerialization.data(withJSONObject: exports, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? data.write(to: output.appending(path: "export-results.json"), options: .atomic)
        }

        private static func submitNativeReturn(panel: NSSavePanel, owner: NSWindow) -> Bool {
            guard panel.isVisible, panel.sheetParent === owner, panel.isKeyWindow,
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false)
            else { return false }
            down.flags = []; up.flags = []
            let pid = ProcessInfo.processInfo.processIdentifier
            down.postToPid(pid); up.postToPid(pid)
            return true
        }

        private static func requestExportCapture(
            panel: NSSavePanel, owner: NSWindow, format: MarkdownFileExport.Format,
            destination: URL, output: URL, trace: NativeExportSmokeTrace
        ) async {
            guard ProcessInfo.processInfo.environment["DIETER_CONTENT_CAPTURE"] == "1" else { return }
            let phase = "export-\(format.rawValue)"
            let request = output.appending(path: "capture-request.json")
            let acknowledgement = output.appending(path: "capture-ack-\(phase)")
            try? FileManager.default.removeItem(at: acknowledgement)
            let marker = [
                "phase": phase, "windowNumber": String(panel.windowNumber),
                "ownerWindowNumber": String(owner.windowNumber),
                "suggestedFilename": destination.lastPathComponent, "destination": destination.path,
                "action": "Click the visible Export button, then acknowledge. Do not cancel the Save panel.",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: request, options: .atomic)
            }
            trace.record("awaiting external Export click", panel: panel, owner: owner)
            defer { try? FileManager.default.removeItem(at: request) }
            // Acknowledging a screenshot is insufficient: require the actual
            // Save sheet to close, then verify the exported bytes below.
            _ = await NativeUIAccessibility.wait(timeout: 60) {
                !panel.isVisible && owner.attachedSheet == nil
            }
            trace.record("external capture finished", panel: panel, owner: owner)
        }

        static func finderAvailability(
            store: DieterStore, tab: ConversationContentTab, window: NSWindow,
            results: inout [String: String]
        ) async {
            let identifier = "conversation.content.file.\(tab.id.uuidString).show-in-finder"
            let ready = await NativeUIAccessibility.wait(timeout: 5) {
                NativeUIAccessibility.find(identifier, in: window) != nil
                    && nativeButton(identifier, in: window) != nil
            }
            let button = nativeButton(identifier, in: window)
            let enabled = button?.isEnabled
            let expectedEnabled = store.rpc?.isLoopbackDataPlane == true
            let name = tab.files.fileDocument?.name ?? "unknown"
            results["content-finder-\(name)"] =
                ready && enabled == expectedEnabled
                ? "passed"
                : "failed: visible=\(ready), enabled=\(String(describing: enabled)), verified local=\(expectedEnabled)"
        }

        private static func savePanel(for window: NSWindow) -> NSSavePanel? {
            NSApp.windows.compactMap { $0 as? NSSavePanel }.first {
                $0.isVisible && ($0.sheetParent === window || window.attachedSheet === $0)
            }
        }
        private static func nativeButton(_ identifier: String, in window: NSWindow) -> NSButton? {
            guard
                let anchor = NativeUISmokeTargets.frames[identifier]?.compactMap(\.view).first(where: {
                    $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0
                        && $0.bounds.height > 0
                })
            else { return nil }
            let frame = anchor.convert(anchor.bounds, to: nil)
            let center = NSPoint(x: frame.midX, y: frame.midY)
            var ancestor = anchor.superview
            while let root = ancestor {
                var pending = [root]
                var matches: [NSButton] = []
                while let view = pending.popLast() {
                    if let button = view as? NSButton, !(button is NSPopUpButton),
                        button.window === window, !button.isHiddenOrHasHiddenAncestor,
                        button.convert(button.bounds, to: nil).contains(center)
                    {
                        matches.append(button)
                    }
                    pending.append(contentsOf: view.subviews)
                }
                if let match = matches.min(by: {
                    let left = $0.convert($0.bounds, to: nil)
                    let right = $1.convert($1.bounds, to: nil)
                    return abs(left.midX - frame.midX) + abs(left.midY - frame.midY)
                        < abs(right.midX - frame.midX) + abs(right.midY - frame.midY)
                }) {
                    return match
                }
                ancestor = root.superview
            }
            return nil
        }
    }

    @MainActor private final class NativeExportSmokeTrace {
        private let destination: URL
        private var stages: [String] = []

        init(output: URL, format: MarkdownFileExport.Format) {
            destination = output.appending(path: "export-\(format.rawValue)-diagnostics.json")
        }

        func record(_ stage: String, panel: NSSavePanel? = nil, owner: NSWindow? = nil) {
            var line = "\(ProcessInfo.processInfo.systemUptime) \(stage)"
            if let panel {
                line += " title=\(panel.title) visible=\(panel.isVisible) key=\(panel.isKeyWindow)"
                line += " panel=\(panel.windowNumber) parent=\(panel.sheetParent?.windowNumber ?? -1)"
                line += " owner=\(owner?.windowNumber ?? -1) attached=\(owner?.attachedSheet?.windowNumber ?? -1)"
                line += " directory=\(panel.directoryURL?.path ?? "nil") filename=\(panel.nameFieldStringValue)"
                line += " prompt=\(panel.prompt) result=\(panel.url?.path ?? "nil")"
                line += " defaultButton=\(String(describing: panel.defaultButtonCell?.isEnabled))"
            }
            stages.append(line)
            if let data = try? JSONSerialization.data(withJSONObject: stages, options: [.prettyPrinted]) {
                try? data.write(to: destination, options: .atomic)
            }
        }
    }

    @MainActor final class NativeContentMenuTracker: NSObject {
        var menu: NSMenu?
        override init() {
            super.init()
            // AppKit posts menu tracking notifications on the main thread.
            NotificationCenter.default.addObserver(
                self, selector: #selector(menuBeganTracking(_:)),
                name: NSMenu.didBeginTrackingNotification, object: nil)
        }
        @objc private func menuBeganTracking(_ notification: Notification) {
            menu = notification.object as? NSMenu
        }
        func stop() {
            NotificationCenter.default.removeObserver(self)
        }
    }
#endif
