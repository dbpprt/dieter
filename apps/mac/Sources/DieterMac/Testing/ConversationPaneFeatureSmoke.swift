#if DIETER_UI_SMOKE
    import AppKit
    import DieterAPI
    import Foundation
    import Network
    import PDFKit
    import SwiftTerm
    import WebKit

    /// Additional journeys for the tabbed content workspace. All daemon
    /// mutations belong to the smoke driver's disposable project and card.
    @MainActor enum ConversationPaneFeatureSmoke {
        static func run(
            store: DieterStore, window: NSWindow, cardID: String,
            results: inout [String: String], output: URL
        ) async {
            if let index = store.conversationModel.olderConversationMessages.firstIndex(where: {
                $0.id == "message_linked_content_smoke"
            }) {
                var message = store.conversationModel.olderConversationMessages[index]
                message.parts[0].text = """
                    The workspace is ready to review.

                    [Open the implementation plan](side-by-side-smoke.md) to update its checklist, or inspect the [source](side-by-side-smoke.swift#L42).

                    Files stay editable while you move between tabs. Browser pages, terminal sessions, and the project diff share the same workspace.
                    """
                store.conversationModel.olderConversationMessages[index] = message
            }
            await nativeLinkContextMenu(store, window, cardID, &results)
            await markdownAndTabs(store, window, cardID, &results, output)
            await browser(store, window, cardID, &results, output)
            await terminal(store, window, cardID, &results, output)
            await processes(store, window, cardID, &results, output)
            await review(store, window, cardID, &results, output)
            await presentation(store, window, cardID, &results, output)
            await attachments(store, window, cardID, &results, output)
            store.conversationContext.content.hide()
        }

        private static func processes(
            _ store: DieterStore, _ window: NSWindow, _ cardID: String,
            _ results: inout [String: String], _ output: URL
        ) async {
            guard let rpc = store.rpc else { results["content-processes"] = "failed: machine unavailable"; return }
            let content = store.conversationContext.content
            var executionID: String?
            do {
                var request = Dieter_V1_StartExecutionRequest()
                request.cardID = cardID; request.name = "Native process smoke"
                request.argv = [
                    "/bin/sh", "-c", "printf 'process pane ready\\n'; printf 'process warning\\n' >&2; exec sleep 180",
                ]
                request.stdinEof = true; request.timeoutMs = 180_000
                request.idempotencyKey = "native-processes-\(UUID().uuidString)"
                let execution = try await rpc.startExecution(request)
                executionID = execution.id
                _ = await content.openPanel(.processes, conversationID: cardID)
                guard let tab = content.selectedTab, tab.kind == .processes else { throw CocoaError(.fileReadUnknown) }
                let loaded = await wait {
                    tab.processes.selectedID == execution.id
                        && String(decoding: tab.processes.stdout, as: UTF8.self).contains("process pane ready")
                        && String(decoding: tab.processes.stderr, as: UTF8.self).contains("process warning")
                        && NativeUIAccessibility.find("conversation.content.processes", in: window) != nil
                }
                results["content-processes-output"] =
                    loaded ? "passed" : "failed: scoped process list/output unavailable"
                let aligned = await wait {
                    guard
                        let viewport = NativeUIAccessibility.find(
                            "conversation.content.processes.output-viewport", in: window)?.recordedFrame,
                        let heading = NativeUIAccessibility.find(
                            "conversation.content.processes.stdout-heading", in: window)?.recordedFrame
                    else { return false }
                    let leftInset = heading.minX - viewport.minX
                    let topInset = viewport.maxY - heading.maxY
                    return leftInset >= 0 && leftInset <= 24 && topInset >= 0 && topInset <= 24
                }
                results["content-processes-output-alignment"] =
                    aligned ? "passed" : "failed: short output was not aligned to the viewport's top-left"
                await captureStage(window, output, "processes", "08g-content-processes.png")
                let closeClicked = NativeUIAccessibility.click(
                    "conversation.content.tab.\(tab.id.uuidString).close", in: window)
                let closed = await wait { !content.tabs.contains(where: { $0.id == tab.id }) }
                let retained = try await rpc.executions(projectID: execution.projectID, cardID: cardID)
                results["content-processes-close-detaches"] =
                    closeClicked && closed
                        && retained.executions.contains(where: { $0.id == execution.id && $0.status == "running" })
                    ? "passed" : "failed: closing Processes stopped or lost the registered command"
                _ = await content.openPanel(.processes, conversationID: cardID)
                guard let reopened = content.selectedTab, reopened.kind == .processes else {
                    throw CocoaError(.fileReadUnknown)
                }
                let ready = await wait {
                    reopened.processes.selectedID == execution.id
                        && NativeUIAccessibility.find("conversation.content.processes.stop", in: window) != nil
                }
                let clicked = ready && NativeUIAccessibility.click("conversation.content.processes.stop", in: window)
                let stopped = await wait { reopened.processes.selected?.status == "canceled" }
                results["content-processes-explicit-stop"] =
                    clicked && stopped ? "passed" : "failed: native Stop did not cancel the selected process"
                _ = await content.closeTab(reopened.id)
            } catch { results["content-processes"] = "failed: \(error)" }
            // Only this fixture-owned process is cleaned up; no tab close or
            // watch teardown sends a cancellation in production.
            if let executionID { _ = try? await rpc.cancelExecution(id: executionID) }
        }

        private static func nativeLinkContextMenu(
            _ store: DieterStore, _ window: NSWindow, _ cardID: String, _ results: inout [String: String]
        ) async {
            let label = "Open the implementation plan"
            let ready = await wait {
                descendants(window.contentView, as: MessageTextView.self).contains { $0.string.contains(label) }
            }
            guard ready,
                let text = descendants(window.contentView, as: MessageTextView.self).first(where: {
                    $0.string.contains(label) && $0.window === window
                })
            else { results["content-link-context-menu"] = "failed: visible transcript link unavailable"; return }
            let pasteboard = NSPasteboard.general
            let savedPasteboard = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { values, type in
                    values[type] = item.data(forType: type)
                }
            }
            defer {
                pasteboard.clearContents()
                let items = savedPasteboard.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { pasteboard.writeObjects(items) }
            }
            for action in ["Copy Link", "Open in Dieter"] {
                let tracker = NativeContentMenuTracker()
                defer { tracker.stop() }
                let range = (text.string as NSString).range(of: label)
                let interior = NSRange(location: range.location + range.length / 2, length: 1)
                let rectangle = text.firstRect(forCharacterRange: interior, actualRange: nil)
                let point = window.convertPoint(fromScreen: NSPoint(x: rectangle.midX, y: rectangle.midY))
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    if let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                        pressure: type == .rightMouseDown ? 1 : 0)
                    {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                let menuReady = await wait {
                    tracker.menu?.items.contains(where: { $0.title == action && $0.isEnabled }) == true
                }
                guard menuReady, let menu = tracker.menu else {
                    tracker.menu?.cancelTrackingWithoutAnimation()
                    results["content-link-context-\(action)"] = "failed: real right-click menu action absent"
                    continue
                }
                let external = menu.items.first { $0.title == "Open in…" }
                let finder = menu.items.first { $0.title == "Show in Finder" }
                let resolved = await wait {
                    external?.submenu?.items.contains(where: { $0.title == "Loading…" }) == false
                }
                let remoteCorrect = store.rpc?.isLoopbackDataPlane == true || finder?.isEnabled == false
                results["content-link-context-menu"] =
                    external?.submenu != nil && finder != nil && resolved && remoteCorrect
                    ? "passed" : "failed: external submenu/Finder missing or remote file enabled"
                if action == "Copy Link" {
                    pasteboard.clearContents(); pasteboard.setString("Unchanged link clipboard", forType: .string)
                }
                guard let index = menu.items.firstIndex(where: { $0.title == action }) else {
                    menu.cancelTrackingWithoutAnimation()
                    results["content-link-context-\(action)"] = "failed: context action vanished during resolution"
                    continue
                }
                menu.cancelTrackingWithoutAnimation()
                menu.performActionForItem(at: index)
                let acted = await wait {
                    if action == "Copy Link" { return pasteboard.string(forType: .string) == "side-by-side-smoke.md" }
                    let model = store.conversationContext.content
                    return model.isOpen && model.selection == .file(path: "side-by-side-smoke.md", line: nil)
                        && model.files.fileDocument?.name == "side-by-side-smoke.md"
                }
                results["content-link-context-\(action)"] =
                    acted ? "passed" : "failed: native menu action did not copy/open the scoped link"
            }
        }

        private static func markdownAndTabs(
            _ store: DieterStore, _ window: NSWindow, _ cardID: String,
            _ results: inout [String: String], _ output: URL
        ) async {
            let model = store.conversationContext.content
            _ = await model.open(URL(string: "side-by-side-smoke.md")!, conversationID: cardID)
            let loaded = await wait { richEditor(window, source: model.files.fileEditorSession.currentText()) != nil }
            guard loaded, let tab = model.selectedTab,
                let editor = richEditor(window, source: tab.files.fileEditorSession.currentText())
            else { results["content-markdown-interactive"] = "failed: editable Markdown surface unavailable"; return }
            let original = editor.string
            // Native Markdown paste trims outer whitespace; the document already ends in a newline.
            let addition = "Implementation reviewed in the content pane."
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            await NativeUIAccessibility.type(addition, in: window)
            let edited = await wait { tab.files.fileEditorSession.currentText() == original + addition && tab.dirty }
            window.makeFirstResponder(nil)
            results["content-markdown-interactive"] =
                edited
                ? "passed"
                : "failed: dirty=\(tab.dirty), native source matches buffer=\(editor.string == tab.files.fileEditorSession.currentText()), expected=\((original + addition).debugDescription), actual=\(tab.files.fileEditorSession.currentText().debugDescription)"

            // TextKit supplies the screen rectangle for the hidden [ ] marker;
            // its native checkbox is drawn immediately to the left of it.
            let checkbox = (editor.string as NSString).range(of: "[ ]")
            if checkbox.location != NSNotFound {
                editor.scrollRangeToVisible(checkbox)
                try? await DieterTaskSleep.milliseconds(150)
                let rectangle = editor.firstRect(forCharacterRange: checkbox, actualRange: nil)
                let point = window.convertPoint(fromScreen: NSPoint(x: rectangle.minX - 10, y: rectangle.midY))
                click(point, window: window)
                let checked = await wait {
                    tab.files.fileEditorSession.currentText().contains("[x] Review the implementation")
                }
                results["content-markdown-checkbox"] =
                    checked ? "passed" : "failed: native checkbox did not toggle its Markdown source"
            } else {
                results["content-markdown-checkbox"] = "failed: checkbox fixture absent"
            }

            await markdownModes(tab: tab, editor: editor, window: window, results: &results)
            await ConversationFileActionsUISmoke.finderAvailability(
                store: store, tab: tab, window: window, results: &results)
            await ConversationFileActionsUISmoke.exportUnsavedDraft(
                store: store, tab: tab, window: window, results: &results, output: output)
            _ = await model.open(URL(string: "side-by-side-smoke.swift#L42")!, conversationID: cardID)
            if let sourceTab = model.selectedTab {
                await ConversationFileActionsUISmoke.finderAvailability(
                    store: store, tab: sourceTab, window: window, results: &results)
            }
            let second = model.selectedTabID
            let focused = NativeUIAccessibility.click("conversation.content.tab.\(tab.id.uuidString)", in: window)
            let retained = await wait {
                model.selectedTabID == tab.id && model.tabs.count >= 2 && tab.dirty
                    && tab.files.fileEditorSession.currentText().contains(addition)
                    && richEditor(window, source: tab.files.fileEditorSession.currentText()) != nil
            }
            results["content-tabs-preserve-dirty-editor"] =
                focused && retained && second != tab.id
                ? "passed" : "failed: focus=\(focused), dirty editor retained=\(retained), tabs=\(model.tabs.count)"

            let closeClicked = NativeUIAccessibility.click(
                "conversation.content.tab.\(tab.id.uuidString).close", in: window)
            let prompted = await wait { window.attachedSheet != nil && model.confirming }
            if let sheet = window.attachedSheet,
                let cancel = descendants(sheet.contentView, as: NSButton.self).first(where: { $0.title == "Cancel" })
            {
                click(cancel, window: sheet)
            }
            let canceled = await wait {
                window.attachedSheet == nil && !model.confirming && model.tabs.contains(where: { $0.id == tab.id })
            }
            results["content-dirty-close-cancel"] =
                closeClicked && prompted && canceled && tab.dirty
                ? "passed"
                : "failed: close=\(closeClicked), prompt=\(prompted), canceled=\(canceled), dirty=\(tab.dirty)"

            let savedText = tab.files.fileEditorSession.currentText()
            let saveClicked = NativeUIAccessibility.click("conversation.content.save", in: window)
            let saved = await wait { !tab.dirty && !tab.files.saving }
            do {
                guard let rpc = store.rpc else { throw CocoaError(.fileReadNoPermission) }
                var read = Dieter_V1_ReadFileRequest()
                read.projectID = tab.files.target.projectID; read.cardID = cardID; read.path = "side-by-side-smoke.md"
                let document = try await rpc.readFile(read)
                results["content-markdown-save"] =
                    saveClicked && saved && document.content == savedText
                    ? "passed"
                    : "failed: save click=\(saveClicked), clean=\(saved), scoped disk matches=\(document.content == savedText)"
            } catch { results["content-markdown-save"] = "failed: \(error)" }
            await captureStage(window, output, "markdown", "08a-content-markdown.png")

            let closed = NativeUIAccessibility.click("conversation.content.tab.\(tab.id.uuidString).close", in: window)
            let removed = await wait { !model.tabs.contains(where: { $0.id == tab.id }) }
            _ = await model.open(URL(string: "side-by-side-smoke.md")!, conversationID: cardID)
            let reopened = await wait {
                model.selectedTabID != tab.id && richEditor(window, source: savedText)?.isEditable == true
            }
            results["content-markdown-reopen-default-edit"] =
                closed && removed && reopened
                ? "passed" : "failed: close=\(closed), removed=\(removed), reopened rich Edit=\(reopened)"

            _ = await model.openPanel(.files, conversationID: cardID)
            guard let navigatorTab = model.selectedTab else {
                results["content-file-tree-open"] = "failed: Files tab unavailable"; return
            }
            let rowID = "conversation.content.files.\(navigatorTab.id.uuidString).row.side-by-side-smoke.swift"
            let rowReady = await wait { NativeUIAccessibility.find(rowID, in: window) != nil }
            let rowClicked = rowReady && NativeUIAccessibility.click(rowID, in: window)
            let fileOpened = await wait { model.files.fileDocument?.name == "side-by-side-smoke.swift" }
            results["content-file-tree-open"] =
                rowClicked && fileOpened
                ? "passed"
                : "failed: row=\(rowReady), native click=\(rowClicked), opened=\(fileOpened), selected=\(String(describing: model.selection)), error=\(model.error ?? model.files.fileError ?? "none")"
            await markdownRelativeLink(store, window, cardID, &results)
        }

        private static func markdownModes(
            tab: ConversationContentTab, editor: NSTextView, window: NSWindow, results: inout [String: String]
        ) async {
            let draft = tab.files.fileEditorSession.currentText()
            let identifier = "files.markdown.layout.\(tab.files.documentKey)"
            let sourceClicked = NativeUIAccessibility.click(identifier, in: window, horizontalFraction: 0.75)
            let sourceReady = await wait {
                descendants(window.contentView, as: SyntaxEditorTextView.self).contains {
                    $0.isEditable && $0.string == draft && $0.window === window
                }
            }
            let source = descendants(window.contentView, as: SyntaxEditorTextView.self).first {
                $0.isEditable && $0.string == draft
            }
            let editClicked = NativeUIAccessibility.click(identifier, in: window, horizontalFraction: 0.25)
            let richRetained = await wait { editor.isEditable && editor.string == draft && tab.dirty }
            let sourceAgain = NativeUIAccessibility.click(identifier, in: window, horizontalFraction: 0.75)
            let sourceRetained = await wait { source?.isEditable == true && source?.string == draft }
            let editAgain = NativeUIAccessibility.click(identifier, in: window, horizontalFraction: 0.25)
            let restored = await wait { editor.isEditable && editor.string == draft && tab.dirty }
            results["content-markdown-edit-source-modes"] =
                MarkdownFileEditorMode.allCases == [.edit, .source] && sourceClicked && sourceReady && editClicked
                    && richRetained && sourceAgain && sourceRetained && editAgain && restored
                ? "passed" : "failed: native Edit/Source switching lost a retained editor or unsaved draft"
        }

        private static func markdownRelativeLink(
            _ store: DieterStore, _ window: NSWindow, _ cardID: String, _ results: inout [String: String]
        ) async {
            do {
                guard let rpc = store.rpc else { throw CocoaError(.fileReadUnknown) }
                let model = store.conversationContext.content
                let projectID = model.files.target.projectID
                var directory = Dieter_V1_CreateFileRequest()
                directory.projectID = projectID; directory.cardID = cardID
                directory.path = "content-guide"; directory.kind = "directory"
                _ = try await rpc.createFile(directory)
                var document = Dieter_V1_CreateFileRequest()
                document.projectID = projectID; document.cardID = cardID
                document.path = "content-guide/plan.md"; document.kind = "file"
                document.content = "# Implementation notes\n\n[View source](../side-by-side-smoke.swift#L42)\n"
                _ = try await rpc.createFile(document)
                let existingSourceID = model.tabs.first {
                    if case .file(path: "side-by-side-smoke.swift", line: _) = $0.selection { return true }
                    return false
                }?.id
                _ = await model.open(URL(string: document.path)!, conversationID: cardID)
                let loaded = await wait { richEditor(window, source: document.content) != nil }
                guard loaded, let editor = richEditor(window, source: document.content) else {
                    results["content-markdown-relative-link"] = "failed: linked Markdown editor unavailable"; return
                }
                let range = (editor.string as NSString).range(of: "View source")
                // Click an interior glyph; the rich editor deliberately reserves link edges for editing.
                let interior = NSRange(location: range.location + range.length / 2, length: 1)
                let rectangle = editor.firstRect(forCharacterRange: interior, actualRange: nil)
                let point = window.convertPoint(fromScreen: NSPoint(x: rectangle.midX, y: rectangle.midY))
                click(point, window: window)
                let opened = await wait {
                    model.selectedTabID == existingSourceID
                        && model.selection == .file(path: "side-by-side-smoke.swift", line: 42)
                        && model.files.fileDocument?.name == "side-by-side-smoke.swift"
                }
                results["content-markdown-relative-link"] =
                    opened
                    ? "passed"
                    : "failed: expected source tab=\(String(describing: existingSourceID)), selected=\(String(describing: model.selectedTabID)), selection=\(String(describing: model.selection)), error=\(model.error ?? model.files.fileError ?? "none")"
            } catch { results["content-markdown-relative-link"] = "failed: \(error)" }
        }

        private static func browser(
            _ store: DieterStore, _ window: NSWindow, _ cardID: String,
            _ results: inout [String: String], _ output: URL
        ) async {
            let model = store.conversationContext.content
            let originalValidation = model.validateWebURL
            // The fixture's gateway route is remote-shaped, but this isolated
            // listener deliberately serves browser test content on the client.
            model.validateWebURL = { _, _ in }
            defer { model.validateWebURL = originalValidation }
            do {
                let server = try ContentBrowserSmokeServer()
                defer { server.stop() }
                guard await wait({ server.baseURL != nil }), let base = server.baseURL else {
                    throw CocoaError(.fileReadUnknown)
                }
                if let index = store.conversationModel.olderConversationMessages.firstIndex(where: {
                    $0.id == "message_linked_content_smoke"
                }) {
                    let address = "127.0.0.1:\(base.port!)"
                    store.conversationModel.olderConversationMessages[index].parts[0].text +=
                        "\n\nThe local preview is running at `\(address)`."
                    let visible = await wait {
                        descendants(window.contentView, as: MessageTextView.self).contains {
                            $0.string.contains(address) && !$0.isHiddenOrHasHiddenAncestor
                        }
                    }
                    if visible,
                        let text = descendants(window.contentView, as: MessageTextView.self).first(where: {
                            $0.string.contains(address) && !$0.isHiddenOrHasHiddenAncestor
                        })
                    {
                        let range = (text.string as NSString).range(of: address)
                        text.scrollRangeToVisible(range)
                        try? await DieterTaskSleep.milliseconds(200)
                        let rect = text.firstRect(forCharacterRange: range, actualRange: nil)
                        click(window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY)), window: window)
                        let opened = await wait {
                            model.selectedTab?.kind == .browser
                                && model.selectedTab?.browser.webView.url?.port == base.port
                                && model.selectedTab?.browser.loading == false
                        }
                        results["content-inline-address-click"] =
                            opened
                            ? "passed" : "failed: native click on bare host:port did not open the browser tab"
                        if let selected = model.selectedTabID { _ = await model.closeTab(selected) }
                    } else {
                        results["content-inline-address-click"] = "failed: inline address not visible"
                    }
                } else {
                    results["content-inline-address-click"] = "failed: transcript fixture missing"
                }
                _ = await model.openPanel(.browser, conversationID: cardID)
                guard let tab = model.selectedTab else { throw CocoaError(.fileReadUnknown) }
                let addressTarget = "conversation.browser.\(tab.id.uuidString).address"
                let addressReady = await stableTarget(addressTarget, in: window)
                let addressClicked = addressReady && NativeUIAccessibility.click(addressTarget, in: window)
                let addressFocused = await wait {
                    guard let field = window.firstResponder as? NSTextView else { return false }
                    return field.isFieldEditor && field.isEditable && field.string.isEmpty
                }
                if addressFocused { await NativeUIAccessibility.type(base.absoluteString, in: window) }
                let enteredAddress = await wait {
                    (window.firstResponder as? NSTextView)?.string == base.absoluteString
                }
                if enteredAddress { pressReturn(window) }
                let firstLoaded = await wait {
                    tab.browser.webView.url?.path == "/" && !tab.browser.loading && tab.browser.failure == nil
                }
                results["content-browser-address"] =
                    addressClicked && addressFocused && enteredAddress && firstLoaded
                    ? "passed"
                    : "failed: address=\(addressClicked), focus=\(addressFocused), entered=\(enteredAddress), page loaded=\(firstLoaded), native URL=\(tab.browser.webView.url?.absoluteString ?? "none"), error=\(tab.browser.failure ?? "none")"
                // This tab now originates from an explicit object open, as a
                // clicked chat link or a harness presentation would create it.
                _ = await model.closeTab(tab.id)
                _ = await model.open(base, conversationID: cardID)
                guard let linkedTab = model.selectedTab else { throw CocoaError(.fileReadUnknown) }
                _ = await wait { linkedTab.browser.webView.url?.path == "/" && !linkedTab.browser.loading }
                let nextClicked = await clickWebLink("next", web: linkedTab.browser.webView, window: window)
                let secondLoaded = await wait {
                    linkedTab.browser.webView.url?.path == "/second" && !linkedTab.browser.loading
                }
                let backClicked = NativeUIAccessibility.click(
                    "conversation.browser.\(linkedTab.id.uuidString).back", in: window)
                let wentBack = await wait { linkedTab.browser.webView.url?.path == "/" && !linkedTab.browser.loading }
                results["content-browser-native-navigation"] =
                    nextClicked && secondLoaded && backClicked && wentBack
                    ? "passed"
                    : "failed: page link=\(nextClicked), next=\(secondLoaded), back=\(backClicked), restored=\(wentBack)"
                let navigatedAgain = await clickWebLink("next", web: linkedTab.browser.webView, window: window)
                let awayAgain = await wait {
                    linkedTab.browser.webView.url?.path == "/second" && !linkedTab.browser.loading
                }
                let count = model.tabs.count
                _ = await model.open(base, conversationID: cardID)
                let revealedOriginal = await wait {
                    model.selectedTabID == linkedTab.id && model.tabs.count == count
                        && linkedTab.browser.webView.url?.path == "/" && !linkedTab.browser.loading
                }
                results["content-browser-reopen-original-url"] =
                    navigatedAgain && awayAgain && revealedOriginal
                    ? "passed"
                    : "failed: native navigate away=\(navigatedAgain && awayAgain), same tab revealed original URL=\(revealedOriginal)"
                await captureStage(window, output, "browser", "08b-content-browser.png")
                let blockedClicked = await clickWebLink("blocked", web: linkedTab.browser.webView, window: window)
                // WebKit can reject an HTTP page's file:// link before its navigation delegate.
                // Verify that native click keeps the page intact, then exercise the app's
                // rejection through the native address field as well.
                try? await DieterTaskSleep.milliseconds(300)
                let stayedOnPage = linkedTab.browser.webView.url == base
                let rejectedAddressClicked = NativeUIAccessibility.click(
                    "conversation.browser.\(linkedTab.id.uuidString).address", in: window)
                let rejectedAddressFocused = await wait {
                    guard let field = window.firstResponder as? NSTextView else { return false }
                    return field.isFieldEditor && field.isEditable
                }
                if rejectedAddressFocused, let field = window.firstResponder as? NSTextView {
                    field.selectAll(nil)
                    await NativeUIAccessibility.type("file:///etc/hosts", in: window)
                }
                let rejectedAddressEntered = await wait {
                    (window.firstResponder as? NSTextView)?.string == "file:///etc/hosts"
                }
                if rejectedAddressEntered { pressReturn(window) }
                let blocked = await wait {
                    linkedTab.browser.failure != nil && linkedTab.browser.webView.url == base
                }
                results["content-browser-blocks-file-scheme"] =
                    blockedClicked && stayedOnPage && rejectedAddressClicked && rejectedAddressFocused
                        && rejectedAddressEntered && blocked
                    ? "passed"
                    : "failed: native file-link=\(blockedClicked), page retained=\(stayedOnPage), address entered=\(rejectedAddressEntered), rejected=\(blocked), URL=\(linkedTab.browser.webView.url?.absoluteString ?? "none"), error=\(linkedTab.browser.failure ?? "none")"
            } catch { results["content-browser-address"] = "failed: \(error)" }
        }

        private static func terminal(
            _ store: DieterStore, _ window: NSWindow, _ cardID: String,
            _ results: inout [String: String], _ output: URL
        ) async {
            let model = store.conversationContext.content
            _ = await model.openPanel(.terminal, conversationID: cardID)
            guard let tab = model.selectedTab, tab.kind == .terminal else {
                results["content-terminal-input"] = "failed: Terminal tab unavailable (\(model.error ?? "no error"))";
                return
            }
            let ready = await wait {
                NativeUIAccessibility.find("conversation.content.terminal.create", in: window) != nil
            }
            let created = ready && NativeUIAccessibility.click("conversation.content.terminal.create", in: window)
            let mounted = await wait(timeout: 15) {
                tab.terminals.selectedTerminalID != nil && tab.terminals.terminalStreamConnected
                    && tab.terminals.selectedTerminal?.status == "running"
                    && descendants(window.contentView, as: RemoteTerminalView.self).contains {
                        !$0.isHiddenOrHasHiddenAncestor && $0.visibleRect.width > 0
                    }
            }
            guard mounted, let terminalID = tab.terminals.selectedTerminalID,
                let view = descendants(window.contentView, as: RemoteTerminalView.self).first(where: {
                    $0.visibleRect.width > 0
                })
            else {
                results["content-terminal-input"] =
                    "failed: create=\(created), native terminal=\(mounted), error=\(tab.terminals.errorMessage ?? "none")";
                return
            }
            click(view, window: window)
            let marker = "CONTENT_TERMINAL_VERIFIED"
            await NativeUIAccessibility.type("printf '\\n\(marker)\\n'", in: window)
            pressReturn(window)
            let received = await wait(timeout: 15) {
                (0..<view.terminal.rows).compactMap {
                    view.terminal.getLine(row: $0)?.translateToString(trimRight: true)
                }
                .contains { $0.trimmingCharacters(in: .whitespaces) == marker }
            }
            results["content-terminal-input"] =
                created && received ? "passed" : "failed: create=\(created), native output=\(received)"
            await captureStage(window, output, "terminal", "08c-content-terminal.png")
            let closed = NativeUIAccessibility.click("conversation.content.tab.\(tab.id.uuidString).close", in: window)
            _ = await wait { !model.tabs.contains(where: { $0.id == tab.id }) }
            do {
                guard let rpc = store.rpc else { throw CocoaError(.fileReadUnknown) }
                let sessions = try await rpc.terminals(projectID: tab.terminals.target.projectID, cardID: cardID)
                results["content-terminal-survives-tab-close"] =
                    closed && sessions.terminals.contains { $0.id == terminalID && $0.status == "running" }
                    ? "passed" : "failed: tab close=\(closed), persistent shell missing or stopped"
                // Explicitly clean up only the shell created by this fixture.
                try await rpc.closeTerminal(id: terminalID)
            } catch { results["content-terminal-survives-tab-close"] = "failed: \(error)" }
        }

        private static func review(
            _ store: DieterStore, _ window: NSWindow, _ cardID: String,
            _ results: inout [String: String], _ output: URL
        ) async {
            let model = store.conversationContext.content
            _ = await model.openPanel(.review, conversationID: cardID)
            guard let tab = model.selectedTab, tab.kind == .review else {
                results["content-review-scoped-diff"] = "failed: Review tab unavailable (\(model.error ?? "none"))";
                return
            }
            let row =
                tab.usesProjectReview
                ? "project-changes.unstaged.side-by-side-smoke.swift" : "changes.file.side-by-side-smoke.swift"
            let ready = await wait(timeout: 15) { NativeUIAccessibility.find(row, in: window) != nil }
            let clicked = ready && NativeUIAccessibility.click(row, in: window)
            let diff = await wait {
                if tab.usesProjectReview {
                    return tab.projectReview.projectID == tab.scope?.target.projectID
                        && tab.projectReview.selection?.path == "side-by-side-smoke.swift"
                        && tab.projectReview.diff?.cardID.isEmpty == true
                        && tab.projectReview.diff?.patch.contains("smokeLine42") == true
                }
                return tab.review.target.conversationID == cardID
                    && tab.review.selectedChangePath == "side-by-side-smoke.swift"
                    && tab.review.conversationDiff?.patch.contains("smokeLine42") == true
            }
            results["content-review-scoped-diff"] =
                clicked && diff
                ? "passed"
                : "failed: row=\(ready), click=\(clicked), project scope=\(tab.usesProjectReview), scoped diff=\(diff), error=\(tab.projectReview.refreshError ?? tab.projectReview.diffError ?? tab.review.workspaceError ?? "none")"
            results["content-review-project-workspace"] =
                tab.usesProjectReview && diff
                ? "passed" : "failed: project-workspace card did not use project changes and project-scoped file diff"
            await captureStage(window, output, "review", "08d-content-review.png")
        }

        private static func presentation(
            _ store: DieterStore, _ window: NSWindow, _ cardID: String,
            _ results: inout [String: String], _ output: URL
        ) async {
            do {
                guard let rpc = store.rpc else { throw CocoaError(.fileReadUnknown) }
                let model = store.conversationContext.content
                model.hide()
                var request = Dieter_V1_PresentConversationContentRequest()
                request.cardID = cardID; request.path = "side-by-side-smoke.swift"; request.line = 42
                request.title = "Implementation"
                let presented = try await rpc.presentConversationContent(request)
                let opened = await wait(timeout: 15) {
                    model.isOpen && model.selection == .file(path: "side-by-side-smoke.swift", line: 42)
                        && model.files.fileDocument?.name == "side-by-side-smoke.swift"
                }
                results["content-agent-presentation"] =
                    !presented.id.isEmpty && opened
                    ? "passed" : "failed: presentation id=\(presented.id), opened from authoritative event=\(opened)"
                capture(window, output.appending(path: "08e-content-agent-presentation.png"))
            } catch { results["content-agent-presentation"] = "failed: \(error)" }
        }

        private static func attachments(
            _ store: DieterStore, _ window: NSWindow, _ cardID: String,
            _ results: inout [String: String], _ output: URL
        ) async {
            // Binary file creation is outside the text-only file RPC. Generate
            // assets only in this driver's disposable workspace, then exercise
            // their normal scoped file reads and native renderers.
            do {
                guard let rpc = store.rpc else { throw CocoaError(.fileReadUnknown) }
                let workspace = try await rpc.workspace(cardID: cardID)
                let root = URL(fileURLWithPath: workspace.path, isDirectory: true).resolvingSymlinksInPath()
                let fixtureRoot = output.appending(path: "fixture-home", directoryHint: .isDirectory)
                    .resolvingSymlinksInPath()
                guard root.path.hasPrefix(fixtureRoot.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
                let image = NSImage(size: NSSize(width: 480, height: 280), flipped: false) { rectangle in
                    NSColor.windowBackgroundColor.setFill(); rectangle.fill()
                    ("Workspace preview" as NSString).draw(
                        at: NSPoint(x: 30, y: 120),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.labelColor])
                    return true
                }
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:]), let page = PDFPage(image: image)
                else { throw CocoaError(.fileWriteUnknown) }
                let pdf = PDFDocument(); pdf.insert(page, at: 0)
                guard let pdfData = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
                for (name, data, identifier) in [
                    ("content-preview.png", png, "conversation.content.image"),
                    ("content-preview.pdf", pdfData, "conversation.content.pdf"),
                    ("content-preview.bin", Data([0, 1, 2, 255, 0, 254]), "conversation.content.download"),
                ] {
                    try data.write(to: root.appending(path: name), options: .atomic)
                    _ = await store.conversationContext.content.open(URL(string: name)!, conversationID: cardID)
                    let rendered = await wait { NativeUIAccessibility.find(identifier, in: window) != nil }
                    results["content-renderer-\(name)"] = rendered ? "passed" : "failed: \(identifier) not mounted"
                    if let tab = store.conversationContext.content.selectedTab {
                        await ConversationFileActionsUISmoke.finderAvailability(
                            store: store, tab: tab, window: window, results: &results)
                    }
                    capture(window, output.appending(path: "08f-\(name).png"))
                }
            } catch { results["content-additional-renderers"] = "failed: \(error)" }
        }

        private static func richEditor(_ window: NSWindow, source: String) -> NSTextView? {
            descendants(window.contentView, as: NSTextView.self).first {
                $0.isEditable && $0.string == source && String(reflecting: type(of: $0)).contains("MarkdownEngine")
            }
        }
        private static func descendants<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            return (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, as: type) }
        }
        private static func wait(timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) async -> Bool {
            await NativeUIAccessibility.wait(timeout: timeout, until: condition)
        }
        private static func pressReturn(_ window: NSWindow) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
                {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        private static func click(_ view: NSView, window: NSWindow) {
            click(view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), window: window)
        }
        private static func click(_ point: NSPoint, window: NSWindow) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0)
                {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        private static func clickWebLink(_ id: String, web: WKWebView, window: NSWindow) async -> Bool {
            // URL/KVO can update before WebKit commits the document. Wait for
            // the actual DOM link and stable native geometry, then click once.
            var previousPoint: NSPoint?
            var stableSamples = 0
            for _ in 0..<80 {
                let value = try? await web.evaluateJavaScript(
                    "(() => {if(document.readyState !== 'complete') return null; const e=document.getElementById('\(id)'); if(!e) return null; const r=e.getBoundingClientRect(); return r.width>0 && r.height>0 ? [r.x+r.width/2,r.y+r.height/2] : null})()"
                )
                if let values = value as? [Double], values.count == 2, web.window === window,
                    !web.isHiddenOrHasHiddenAncestor, web.bounds.width > 0, web.bounds.height > 0
                {
                    let point = NSPoint(x: values[0], y: web.isFlipped ? values[1] : web.bounds.height - values[1])
                    let nativePoint = web.convert(point, to: nil)
                    if web.bounds.contains(point), window.contentView?.bounds.contains(nativePoint) == true {
                        stableSamples = previousPoint == nativePoint ? stableSamples + 1 : 0
                        previousPoint = nativePoint
                        if stableSamples >= 3 { click(nativePoint, window: window); return true }
                    }
                } else {
                    stableSamples = 0
                }
                try? await DieterTaskSleep.milliseconds(100)
            }
            return false
        }
        private static func stableTarget(_ identifier: String, in window: NSWindow) async -> Bool {
            var previousFrame: NSRect?
            var stableSamples = 0
            return await wait {
                guard let target = NativeUIAccessibility.find(identifier, in: window),
                    target.recordedWindow === window, let frame = target.recordedFrame,
                    frame.width > 0, frame.height > 0,
                    window.frame.contains(NSPoint(x: frame.midX, y: frame.midY))
                else { stableSamples = 0; return false }
                stableSamples = previousFrame == frame ? stableSamples + 1 : 0
                previousFrame = frame
                return stableSamples >= 3
            }
        }
        private static func capture(_ window: NSWindow, _ destination: URL) {
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: destination)
        }
        private static func captureStage(_ window: NSWindow, _ output: URL, _ phase: String, _ filename: String) async {
            capture(window, output.appending(path: filename))
            guard ProcessInfo.processInfo.environment["DIETER_CONTENT_CAPTURE"] == "1" else { return }
            let marker = ["phase": phase, "windowNumber": String(window.windowNumber), "suggestedFilename": filename]
            if let data = try? JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appending(path: "capture-request.json"), options: .atomic)
            }
            let acknowledgement = output.appending(path: "capture-ack-\(phase)")
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: acknowledgement.path) { break }
                try? await DieterTaskSleep.milliseconds(100)
            }
            try? FileManager.default.removeItem(at: output.appending(path: "capture-request.json"))
        }
    }

    @MainActor private final class ContentBrowserSmokeServer {
        private let listener: NWListener
        private var connections: [NWConnection] = []
        private(set) var baseURL: URL?

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    if case .ready = state, let self, let port = self.listener.port {
                        self.baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)/")
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
        }
        func stop() { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() }
        private func accept(_ connection: NWConnection) {
            guard connections.count < 12 else { connection.cancel(); return }
            connections.append(connection)
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let second = String(data: data ?? Data(), encoding: .utf8)?.hasPrefix("GET /second ") == true
                let body = """
                    <!doctype html><html><head><meta name="viewport" content="width=device-width"><style>
                    body{font:16px -apple-system;padding:36px;background:#1e2024;color:#eee;line-height:1.6}h1{font-size:28px}a{color:#8dc7ff;display:block;margin:18px 0}article{max-width:600px}small{color:#aab0bb}
                    </style></head><body><article><small>PROJECT WORKSPACE</small><h1>\(second ? "Implementation notes" : "A linked project page")</h1><p>Keep documentation and project context next to your conversation.</p><a id="next" href="/second">Read implementation notes →</a><a id="blocked" href="file:///etc/hosts">Open an unsupported local-file link</a></article></body></html>
                    """
                let bytes = Data(body.utf8)
                let header = Data(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
                        .utf8)
                connection.send(content: header + bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
#endif
