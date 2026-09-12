#if DIETER_UI_SMOKE
    import AppKit
    import DieterAPI
    import Foundation

    /// Uses a real deferred-start card and file RPCs in the smoke driver's
    /// disposable daemon. Only the transcript is a local renderer fixture.
    @MainActor enum ConversationContentUISmoke {
        static func run(
            store: DieterStore, window: NSWindow, results: inout [String: String], output: URL
        ) async {
            let model = store.conversationContext.content
            defer {
                store.conversationModel.olderConversationMessages.removeAll { $0.id == "message_linked_content_smoke" }
            }
            do {
                let cardID = try await installFixture(store)
                let draft = "Keep my linked-content draft"
                window.makeFirstResponder(nil)
                var previousText: ObjectIdentifier?
                var previousFrame: NSRect?
                var stableSamples = 0
                let ready = await NativeUIAccessibility.wait(timeout: 8) {
                    if !NSApp.isActive || !window.isKeyWindow {
                        NSApp.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                    }
                    guard NSApp.isActive, window.isKeyWindow, let text = messageView(in: window),
                        text.string.contains("Smoke code"), text.frame.width > 0
                    else { stableSamples = 0; return false }
                    let identity = ObjectIdentifier(text)
                    stableSamples = previousText == identity && previousFrame == text.frame ? stableSamples + 1 : 0
                    previousText = identity
                    previousFrame = text.frame
                    return stableSamples >= 4
                }
                guard ready, let text = messageView(in: window),
                    let board = boardController(in: window.contentView),
                    let scroll = text.enclosingScrollView
                else {
                    let text = messageView(in: window)
                    results["content-fixture"] =
                        "failed: ready=\(ready), text=\(text != nil), board=\(boardController(in: window.contentView) != nil), scroll=\(text?.enclosingScrollView != nil), selected=\(store.selectedCardID ?? "none"), expected=\(cardID), messages=\(store.conversationMessages.map(\.id)), history=\(store.conversationModel.olderConversationMessages.map(\.id)), active=\(NSApp.isActive), key=\(window.isKeyWindow)"
                    let native = textViews(in: window.contentView).map {
                        "\(String(reflecting: type(of: $0))) frame=\($0.frame) text=\($0.string.prefix(160))"
                    }.joined(separator: "\n")
                    try? native.write(
                        to: output.appending(path: "content-fixture-native.txt"), atomically: true, encoding: .utf8)
                    capture(window, output.appending(path: "07g-content-fixture-failed.png"))
                    return
                }
                _ = await NativeUIAccessibility.wait(timeout: 5) { atTail(scroll) }
                store.composerText = ""
                _ = await NativeUIAccessibility.wait(timeout: 5) {
                    NativeUIAccessibility.find("conversation.composer", in: window)?.recordedFrame?.width ?? 0 > 0
                }
                let focused = NativeUIAccessibility.click("conversation.composer", in: window)
                let editorReady = await NativeUIAccessibility.wait(timeout: 5) {
                    guard let editor = window.firstResponder as? NSTextView else { return false }
                    return editor.isEditable && editor.string.isEmpty
                }
                if focused && editorReady { await NativeUIAccessibility.type(draft, in: window) }
                let entered = await NativeUIAccessibility.wait(timeout: 5) { store.composerText == draft }
                results["content-draft-input"] =
                    focused && editorReady && entered
                    ? "passed" : "failed: focus=\(focused), editor=\(editorReady), entered=\(entered)"
                guard focused && editorReady && entered else { return }
                window.makeFirstResponder(nil)
                let originalWidth = board.conversationFrame.width
                let host = board.conversationHost
                let clicked = clickLink("Smoke Markdown", in: text, window: window)
                let opened = await NativeUIAccessibility.wait(timeout: 8) {
                    model.files.fileDocument?.name == "side-by-side-smoke.md"
                        && board.maximized && richEditor(in: window.contentView) != nil
                }
                results["content-markdown-link"] =
                    clicked && opened
                    ? "passed"
                    : "failed: native click=\(clicked), rich editor/maximize=\(opened), error=\(model.error ?? model.files.fileError ?? "none")"
                capture(window, output.appending(path: "07g-content-markdown.png"))
                recordIdentity(
                    "markdown", hostMatches: board.conversationHost === host,
                    textMatches: messageView(in: window) === text, draftMatches: store.composerText == draft,
                    output: output)
                guard opened else { _ = await model.close(); return }

                if let pane = NativeUIAccessibility.find("conversation.content-pane", in: window)?.object as? NSView,
                    let split = enclosingContentSplit(pane), split.arrangedSubviews.count == 2
                {
                    let chat = split.arrangedSubviews[0]
                    let content = split.arrangedSubviews[1]
                    _ = await NativeUIAccessibility.wait(timeout: 5) {
                        abs(chat.frame.width - (split.bounds.width - split.dividerThickness) * 0.45) < 3
                    }
                    let fraction = chat.frame.width / max(1, split.bounds.width)
                    results["content-initial-layout"] =
                        chat.frame.width >= 280 && content.frame.width >= 300
                            && abs(fraction - 0.45) < 0.01
                        ? "passed" : "failed: chat=\(chat.frame), content=\(content.frame), split=\(split.bounds)"
                    let target = min(split.bounds.width - 320, chat.frame.width + 65)
                    dragDivider(split, to: target, window: window)
                    let resized = await NativeUIAccessibility.wait(timeout: 5) {
                        abs(chat.frame.width - target) < 3
                    }
                    results["content-native-resize"] =
                        resized && board.conversationHost === host
                        ? "passed" : "failed: requested=\(target), actual=\(chat.frame.width)"
                } else {
                    results["content-native-resize"] = "failed: native content split not found"
                }

                guard let currentText = messageView(in: window) else {
                    results["content-code-link"] = "failed: transcript disappeared while content was open"
                    _ = await model.close()
                    return
                }
                let codeClicked = clickLink("Smoke code", in: currentText, window: window)
                let codeOpened = await NativeUIAccessibility.wait(timeout: 8) {
                    guard model.files.fileDocument?.name == "side-by-side-smoke.swift",
                        let editor = textViews(in: window.contentView).first(where: {
                            $0.string == codeSource && !($0 is MessageTextView)
                        })
                    else { return false }
                    let line = SyntaxHighlightedEditor.range(ofLine: 42, in: codeSource)
                    guard let layout = editor.layoutManager, let container = editor.textContainer else { return false }
                    layout.ensureLayout(for: container)
                    let glyphs = layout.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
                    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                        .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                    return !editor.isEditable && editor.isSelectable && editor.selectedRange() == line
                        && editor.visibleRect.intersects(rect)
                }
                results["content-code-line-link"] =
                    codeClicked && codeOpened
                    ? "passed" : "failed: native click=\(codeClicked), readonly selected/revealed line=\(codeOpened)"
                capture(window, output.appending(path: "07h-content-code-line.png"))
                recordIdentity(
                    "code", hostMatches: board.conversationHost === host,
                    textMatches: messageView(in: window) === text, draftMatches: store.composerText == draft,
                    output: output)

                let closeClicked = NativeUIAccessibility.click("conversation.content.close", in: window)
                let restored = await NativeUIAccessibility.wait(timeout: 8) {
                    !model.isOpen && !board.maximized && abs(board.conversationFrame.width - originalWidth) < 3
                        && store.selectedCardID == cardID && store.composerText == draft
                        && board.conversationHost === host && messageView(in: window) === text
                        && atTail(scroll)
                }
                results["content-close-restores-chat"] =
                    closeClicked && restored
                    ? "passed"
                    : "failed: close=\(closeClicked), restored=\(restored), open=\(model.isOpen), maximized=\(board.maximized), selected=\(store.selectedCardID == cardID), draft=\(store.composerText == draft), host=\(board.conversationHost === host), text=\(messageView(in: window) === text), width=\(board.conversationFrame.width)/\(originalWidth), tail=\(atTail(scroll))"
                recordIdentity(
                    "closed", hostMatches: board.conversationHost === host,
                    textMatches: messageView(in: window) === text, draftMatches: store.composerText == draft,
                    output: output)
                capture(window, output.appending(path: "07i-content-closed.png"))
                if model.isOpen { _ = await model.close() }
                await ConversationPaneFeatureSmoke.run(
                    store: store, window: window, cardID: cardID, results: &results, output: output)
                window.makeFirstResponder(nil)
                store.composerText = ""
            } catch {
                results["content-fixture"] = "failed: \(error)"
                _ = await model.close()
            }
        }

        private static let codeSource = (1...80).map { "let smokeLine\($0) = \($0)" }.joined(separator: "\n") + "\n"

        private static func recordIdentity(
            _ phase: String, hostMatches: Bool, textMatches: Bool, draftMatches: Bool, output: URL
        ) {
            let file = output.appending(path: "content-identity.log")
            let previous = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let line = "\(phase): host=\(hostMatches), text=\(textMatches), draft=\(draftMatches)\n"
            try? (previous + line).write(to: file, atomically: true, encoding: .utf8)
        }

        private static func installFixture(_ store: DieterStore) async throws -> String {
            guard let rpc = store.rpc, let project = store.projects.first,
                let board = store.state.boards.first(where: { $0.projectID == project.id })
            else { throw CocoaError(.fileNoSuchFile) }
            var request = Dieter_V1_CreateConversationRequest()
            request.projectID = project.id
            request.boardID = board.id
            request.title = "Workspace improvements"
            request.prompt = "Review the linked workspace plan and implementation."
            request.lane = "todo"
            request.workspaceMode = "project"
            request.deferStart = true
            let card = try await rpc.createCard(request)
            for (path, content) in [
                (
                    "side-by-side-smoke.md",
                    "# Linked workspace\n\nReview project files alongside the conversation.\n\n## Delivery checklist\n\n- [ ] Review the implementation\n- [ ] Confirm the smoke checks\n\nKeep related files, browser pages, terminals, and changes together.\n"
                ),
                ("side-by-side-smoke.swift", codeSource),
            ] {
                var create = Dieter_V1_CreateFileRequest()
                create.projectID = project.id
                create.cardID = card.id
                create.path = path
                create.kind = "file"
                create.content = content
                _ = try await rpc.createFile(create)
            }
            store.closeConversation()
            // Let the previous conversation's canceled transport and view
            // lifecycle settle before taking ownership of the renderer fixture.
            try? await DieterTaskSleep.milliseconds(500)
            var part = Dieter_V1_MessagePart()
            part.type = "text"
            part.text =
                (1...45).map { "Transcript paragraph \($0) keeps enough history to exercise scroll restoration." }
                .joined(separator: "\n\n")
                + "\n\n[Smoke Markdown](side-by-side-smoke.md) · [Smoke code](side-by-side-smoke.swift#L42)"
            var message = Dieter_V1_UiMessage()
            message.id = "message_linked_content_smoke"
            message.role = "assistant"
            message.parts = [part]
            store.state.cards.removeAll { $0.id == card.id }
            store.state.cards.append(card)
            store.selectedProjectID = project.id
            store.selectedBoardID = board.id
            store.selectedChatID = nil
            store.selectedCardID = card.id
            // Establish the production read/watch lifecycle as well as the
            // workspace RPC scope. Assigning a local snapshot alone leaves
            // agent-originated content presentations without a live consumer.
            await store.fetchConversation(cardID: card.id, chat: false, rpc: rpc)
            guard store.conversation?.conversation.cardID == card.id,
                store.conversationTask != nil
            else { throw CocoaError(.fileReadUnknown) }
            if store.conversation?.conversation.lastSeq == 0 {
                // A zero-sequence watch starts with a replacement snapshot.
                // Wait for it before installing synthetic renderer history,
                // which the authoritative replacement correctly clears.
                let previous = store.conversationModel.onSnapshot
                var receivedInitialWatch = false
                store.conversationModel.onSnapshot = { snapshot, endpointID, refreshedAt in
                    await previous(snapshot, endpointID, refreshedAt)
                    if snapshot.conversation.cardID == card.id { receivedInitialWatch = true }
                }
                let watching = await NativeUIAccessibility.wait(timeout: 8) { receivedInitialWatch }
                store.conversationModel.onSnapshot = previous
                guard watching else { throw CocoaError(.fileReadUnknown) }
            }
            // Keep the daemon's live transcript authoritative. The local
            // renderer fixture lives in earlier history, which metadata and
            // content-presentation deltas intentionally preserve.
            store.conversationModel.olderConversationMessages = [message]
            store.section = .board
            return card.id
        }

        private static func messageView(in window: NSWindow) -> MessageTextView? {
            textViews(in: window.contentView).compactMap { $0 as? MessageTextView }.first {
                $0.string.contains("Smoke Markdown")
            }
        }
        private static func textViews(in view: NSView?) -> [NSTextView] {
            guard let view else { return [] }
            return (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }
        private static func richEditor(in view: NSView?) -> NSTextView? {
            textViews(in: view).first { $0.isEditable && String(reflecting: type(of: $0)).contains("MarkdownEngine") }
        }
        private static func boardController(in view: NSView?) -> BoardConversationSplitController? {
            guard let view else { return nil }
            if let split = view as? NSSplitView, let controller = split.delegate as? BoardConversationSplitController {
                return controller
            }
            return view.subviews.lazy.compactMap { boardController(in: $0) }.first
        }
        private static func enclosingContentSplit(_ view: NSView) -> NSSplitView? {
            var parent = view.superview
            while let candidate = parent {
                if let split = candidate as? NSSplitView, !(split.delegate is BoardConversationSplitController) {
                    return split
                }
                parent = candidate.superview
            }
            return nil
        }
        private static func atTail(_ scroll: NSScrollView) -> Bool {
            guard let document = scroll.documentView else { return false }
            return document.bounds.maxY - scroll.documentVisibleRect.maxY < 4
        }
        private static func clickLink(_ label: String, in text: NSTextView, window: NSWindow) -> Bool {
            let range = (text.string as NSString).range(of: label)
            guard range.location != NSNotFound, let layout = text.layoutManager, let container = text.textContainer,
                text.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) != nil
            else { return false }
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
            let point = NSPoint(x: rect.midX, y: rect.midY)
            guard text.visibleRect.contains(point) else { return false }
            postGesture(from: text.convert(point, to: nil), to: nil, window: window)
            return true
        }
        private static func dragDivider(_ split: NSSplitView, to position: CGFloat, window: NSWindow) {
            let start = split.convert(
                NSPoint(
                    x: split.arrangedSubviews[0].frame.maxX + split.dividerThickness / 2,
                    y: split.bounds.midY), to: nil)
            let end = split.convert(NSPoint(x: position + split.dividerThickness / 2, y: split.bounds.midY), to: nil)
            postGesture(from: start, to: end, window: window)
        }
        private static func postGesture(from start: NSPoint, to end: NSPoint?, window: NSWindow) {
            let steps = end == nil ? 1 : 12
            for index in 0...steps {
                let fraction = CGFloat(index) / CGFloat(steps)
                let point = NSPoint(x: start.x + ((end?.x ?? start.x) - start.x) * fraction, y: start.y)
                let type: NSEvent.EventType =
                    index == 0 ? .leftMouseDown : (index == steps ? .leftMouseUp : .leftMouseDragged)
                if let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.016,
                    windowNumber: window.windowNumber, context: nil, eventNumber: index,
                    clickCount: 1, pressure: index == steps ? 0 : 1)
                {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        private static func capture(_ window: NSWindow, _ destination: URL) {
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: destination)
        }
    }
#endif
