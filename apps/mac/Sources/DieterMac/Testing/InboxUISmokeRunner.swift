#if DIETER_UI_SMOKE
    import AppKit
    import DieterAPI
    import Foundation

    /// A real, authenticated Inbox journey. The gateway owns the deterministic
    /// activity and transcript fixture; this runner only uses rendered controls.
    @MainActor enum InboxUISmokeRunner {
        static func run(store: DieterStore) async {
            let output = WorkspaceUISmokeRunner.outputDirectory()
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var results: [String: String] = [:]
            defer { finish(results, output: output) }
            let connected = await NativeUIAccessibility.wait(timeout: 30) {
                store.workspaceIsLive
                    && store.navigationCards.values.joined().contains { $0.title.hasPrefix("Inbox waiting:") }
            }
            guard connected, let window = NSApp.windows.first(where: { $0.title == "Dieter" && $0.isVisible }) else {
                results["connection-fixture"] = "failed: authenticated workspace unavailable (\(store.phase.label))"
                return
            }
            let trace = NativeUIWindowLifecycleTrace(
                window: window, output: output.appending(path: "window-lifecycle.log"))
            defer { trace.stop() }
            window.setContentSize(NSSize(width: 1_380, height: 900))
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let opened = await click("sidebar.inbox", window)
            let directoryReady = await NativeUIAccessibility.wait {
                store.chats.contains { $0.title.hasPrefix("Inbox chat:") }
            }
            let cards = Array(store.navigationCards.values.joined())
            guard directoryReady,
                let waiting = cards.first(where: { $0.title.hasPrefix("Inbox waiting:") }),
                let review = cards.first(where: { $0.title.hasPrefix("Inbox review:") }),
                let running = cards.first(where: { $0.title.hasPrefix("Inbox running:") }),
                let recent = cards.first(where: { $0.title.hasPrefix("Inbox recent:") }),
                let chat = store.chats.first(where: { $0.title.hasPrefix("Inbox chat:") }),
                let notes = store.chats.first(where: { $0.title.hasPrefix("Inbox notes:") }),
                let pending = cards.first(where: { $0.title.hasPrefix("Inbox pending:") })
            else {
                results["connection-fixture"] = "failed: authenticated Inbox fixture unavailable (\(store.phase.label))"
                return
            }
            results["connection-fixture"] = "passed"
            let feedReady = await NativeUIAccessibility.wait {
                store.section == .inbox && visible("inbox.row.\(waiting.id)", window)
            }
            record("sidebar-inbox", opened && feedReady, &results)
            guard feedReady else { capture(window, "00-inbox-failed.png", output); return }
            let expected = [waiting, review, running, recent, chat, notes]
            let expectedIDs =
                expected.map { "inbox.row.\($0.id)" }
                + ["needs-you", "running", "recent"].map { "inbox.section.\($0)" }
            var seen = Set(expectedIDs.filter { visible($0, window) })
            if let scroll = feedScrollView(window) {
                scroll.contentView.scroll(
                    to: NSPoint(x: 0, y: max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                _ = await NativeUIAccessibility.wait {
                    seen.formUnion(expectedIDs.filter { visible($0, window) })
                    return seen.count == expectedIDs.count
                }
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                _ = await NativeUIAccessibility.waitForInteractiveTarget("inbox.row.\(waiting.id)", in: window)
            }
            record("activity-sections", seen.count == expectedIDs.count, &results)
            record("pending-excluded", !visible("inbox.row.\(pending.id)", window), &results)
            do {
                let archived = try await store.rpc?.archivedCards(boardID: waiting.boardID)
                let fixture = archived?.cards.first { $0.title.hasPrefix("Inbox archived:") }
                record(
                    "archived-excluded", fixture != nil && !visible("inbox.row.\(fixture?.id ?? "")", window), &results)
            } catch { results["archived-excluded"] = "failed: \(error)" }

            let selected = await select(waiting, mode: "row", store: store, window: window)
            record("card-conversation-retains-inbox", selected, &results)
            guard selected else { capture(window, "01-selection-failed.png", output); return }
            record(
                "real-transcript",
                transcriptContains("Native Inbox workspace", in: window.contentView)
                    && store.conversation?.conversation.messages.contains { $0.id.hasPrefix("inbox-assistant-") }
                        == true,
                &results)
            let composerClicked = await click("conversation.composer", window)
            let editorReady = await NativeUIAccessibility.wait {
                (window.firstResponder as? NSTextView)?.isEditable == true
            }
            let draft = "Keep this Inbox draft while switching views."
            if composerClicked && editorReady { await NativeUIAccessibility.type(draft, in: window) }
            record("real-composer", composerClicked && editorReady && store.composerText == draft, &results)
            window.makeFirstResponder(nil)
            await captureAppearances(
                store: store, window: window, name: "01-inbox-list-1380", output: output, results: &results)
            recordLayout("default", store: store, cardID: waiting.id, window: window, results: &results)

            let changesClicked = await click("conversation.content.fixed.changes", window)
            let changesReady = await NativeUIAccessibility.wait {
                store.conversationContext.content.conversationTab.lowercased() == "changes"
                    && visible("changes.open-project", window)
            }
            record("workspace-changes-tab", changesClicked && changesReady && store.section == .inbox, &results)
            capture(window, "02-inbox-workspace.png", output)
            let conversationClicked = await click("conversation-tab-conversation", window)
            let transcriptRestored = await NativeUIAccessibility.wait {
                visible("conversation.composer", window)
                    && transcriptContains("Native Inbox workspace", in: window.contentView)
            }
            record(
                "workspace-return-conversation",
                conversationClicked && transcriptRestored && store.composerText == draft, &results)

            let timelineClicked = await click("inbox.mode.timeline", window)
            let timelineReady = await NativeUIAccessibility.wait { visible("inbox.timeline.\(chat.id)", window) }
            record(
                "timeline-retains-selection",
                timelineClicked && timelineReady && selectedID(store) == waiting.id
                    && store.composerText == draft, &results)
            let chatSelected = await select(chat, mode: "timeline", store: store, window: window)
            record("timeline-standalone-chat", chatSelected && store.selectedChatID == chat.id, &results)
            for hours in [1, 6, 24] {
                let changed = await chooseMenu("inbox.range", title: "Last \(hours)h", window: window)
                let retained = await NativeUIAccessibility.wait {
                    visible("inbox.timeline.\(chat.id)", window) && selectedID(store) == chat.id
                        && store.section == .inbox
                        && visible("inbox.range.current.\(hours)", window)
                }
                record("timeline-range-\(hours)", changed && retained, &results)
            }
            _ = await chooseMenu("inbox.range", title: "Last 1h", window: window)
            await captureAppearances(
                store: store, window: window, name: "03-inbox-timeline-1380", output: output, results: &results)
            let listClicked = await click("inbox.mode.list", window)
            _ = await NativeUIAccessibility.wait { visible("inbox.row.\(chat.id)", window) }
            record(
                "list-retains-chat", listClicked && selectedID(store) == chat.id && store.section == .inbox, &results)
            let listCardSelected = await select(review, mode: "row", store: store, window: window)
            record("list-card-selection", listCardSelected, &results)
            let listChatSelected = await select(chat, mode: "row", store: store, window: window)
            record("list-standalone-chat", listChatSelected && store.selectedChatID == chat.id, &results)

            await replaceSearch("Inbox running:", window: window)
            let queryMatched = await NativeUIAccessibility.wait {
                visible("inbox.row.\(running.id)", window) && !visible("inbox.row.\(waiting.id)", window)
                    && !visible("inbox.row.\(chat.id)", window)
            }
            record("query-filters-feed", queryMatched && selectedID(store) == chat.id, &results)
            await replaceSearch("No matching Inbox activity 9a12", window: window)
            let empty = await NativeUIAccessibility.wait { visible("inbox.empty", window) }
            record(
                "query-empty-retains-detail",
                empty && selectedID(store) == chat.id
                    && visible("conversation.composer", window), &results)
            capture(window, "04-inbox-empty-search.png", output)
            await replaceSearch("", window: window)
            let projectSelected = await chooseMenu("inbox.project-filter", title: "Inbox Notes", window: window)
            let projectFiltered = await NativeUIAccessibility.wait {
                visible("inbox.row.\(notes.id)", window) && !visible("inbox.row.\(chat.id)", window)
                    && !visible("inbox.row.\(waiting.id)", window)
            }
            record("project-filter", projectSelected && projectFiltered && selectedID(store) == chat.id, &results)
            capture(window, "05-inbox-project-filter.png", output)
            let resetProject = await chooseMenu("inbox.project-filter", title: "All projects", window: window)
            let projectReset = await NativeUIAccessibility.wait { visible("inbox.row.\(waiting.id)", window) }
            record("project-filter-reset", resetProject && projectReset, &results)

            _ = await select(waiting, mode: "row", store: store, window: window)
            for width: CGFloat in [1_100, 1_600, 1_380] {
                window.setContentSize(NSSize(width: width, height: 900))
                _ = await NativeUIAccessibility.waitForInteractiveTarget("inbox.resize-divider", in: window)
                recordLayout("width-\(Int(width))", store: store, cardID: waiting.id, window: window, results: &results)
                if width == 1_100 {
                    await captureAppearances(
                        store: store, window: window, name: "06-inbox-narrow-1100", output: output, results: &results)
                }
            }
            await resizeFeed(store: store, window: window, results: &results)
            let closed = await click("board.conversation-close", window)
            let cleared = await NativeUIAccessibility.wait {
                selectedID(store) == nil && store.conversation == nil && visible("inbox.empty-detail", window)
            }
            record(
                "close-retains-inbox",
                closed && cleared && store.section == .inbox
                    && visible("inbox.row.\(waiting.id)", window), &results)
            let reopened = await select(waiting, mode: "row", store: store, window: window)
            record("reopen-after-close", reopened, &results)

            let chatsClicked = await click("sidebar.all-chats", window)
            let chatsReady = await NativeUIAccessibility.wait {
                store.section == .chats && visible("chats.browser-pane", window)
            }
            record("all-chats-navigation-unchanged", chatsClicked && chatsReady, &results)
            if !visible("sidebar.board.\(waiting.boardID)", window) {
                _ = await click("sidebar.project.\(waiting.projectID).toggle", window)
            }
            let boardClicked = await click("sidebar.board.\(waiting.boardID)", window)
            let boardReady = await NativeUIAccessibility.wait {
                store.section == .board && store.selectedBoardID == waiting.boardID
                    && !visible("inbox.browser-pane", window)
            }
            record("board-navigation-unchanged", boardClicked && boardReady, &results)
            _ = await click("sidebar.inbox", window)
            record(
                "return-to-inbox",
                await NativeUIAccessibility.wait { store.section == .inbox && visible("inbox.browser-pane", window) },
                &results)
            let inventory = NativeUIAccessibility.elements(in: window).map {
                "\($0.identifier ?? "-") \($0.text) \($0.frame)"
            }.joined(separator: "\n")
            try? inventory.write(to: output.appending(path: "accessibility.txt"), atomically: true, encoding: .utf8)
        }

        private static func select(_ card: Dieter_V1_Card, mode: String, store: DieterStore, window: NSWindow) async
            -> Bool
        {
            let clicked = await click("inbox.\(mode).\(card.id)", window)
            let ready = await NativeUIAccessibility.wait {
                selectedID(store) == card.id && store.conversation?.detail.card.id == card.id
                    && !store.conversationLoading && visible("conversation.composer", window)
                    && transcriptContains("Native Inbox workspace", in: window.contentView)
            }
            return clicked && ready && store.section == .inbox
        }
        private static func selectedID(_ store: DieterStore) -> String? { store.selectedChatID ?? store.selectedCardID }
        private static func visible(_ id: String, _ window: NSWindow) -> Bool {
            guard let frame = NativeUIAccessibility.find(id, in: window)?.recordedFrame else { return false }
            return frame.width > 0 && frame.height > 0
        }
        private static func click(_ id: String, _ window: NSWindow) async -> Bool {
            guard await NativeUIAccessibility.waitForInteractiveTarget(id, in: window) else { return false }
            return NativeUIAccessibility.click(id, in: window)
        }
        private static func feedScrollView(_ window: NSWindow) -> NSScrollView? {
            guard let target = NativeUIAccessibility.find("inbox.feed", in: window)?.recordedFrame,
                let root = window.contentView
            else { return nil }
            var pending = [root]
            while let view = pending.popLast() {
                pending.append(contentsOf: view.subviews)
                if let scroll = view as? NSScrollView,
                    (scroll.documentView?.frame.height ?? 0) > scroll.contentSize.height + 1
                {
                    let frame = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                    if target.contains(NSPoint(x: frame.midX, y: frame.midY)) { return scroll }
                }
            }
            return nil
        }

        private static func transcriptContains(_ text: String, in view: NSView?) -> Bool {
            guard let view, !view.isHiddenOrHasHiddenAncestor else { return false }
            if let message = view as? MessageTextView, message.string.contains(text) { return true }
            return view.subviews.contains { transcriptContains(text, in: $0) }
        }
        private static func replaceSearch(_ query: String, window: NSWindow) async {
            guard await click("inbox.search", window) else { return }
            _ = await NativeUIAccessibility.wait { (window.firstResponder as? NSTextView)?.isEditable == true }
            guard let editor = window.firstResponder as? NSTextView else { return }
            editor.selectAll(nil)
            if query.isEmpty { editor.deleteBackward(nil) } else { await NativeUIAccessibility.type(query, in: window) }
            window.makeFirstResponder(nil)
        }
        private static func chooseMenu(_ id: String, title: String, window: NSWindow) async -> Bool {
            let tracker = NativeContentMenuTracker()
            defer { tracker.menu?.cancelTrackingWithoutAnimation(); tracker.stop() }
            guard await click(id, window) else { return false }
            guard
                await NativeUIAccessibility.wait(
                    timeout: 5,
                    until: {
                        tracker.menu?.items.contains { $0.title == title && $0.isEnabled } == true
                    }), let menu = tracker.menu,
                let index = menu.items.firstIndex(where: { $0.title == title && $0.isEnabled })
            else { return false }
            menu.cancelTrackingWithoutAnimation()
            menu.performActionForItem(at: index)
            return true
        }
        private static func recordLayout(
            _ key: String, store: DieterStore, cardID: String, window: NSWindow, results: inout [String: String]
        ) {
            let feed = NativeUIAccessibility.find("inbox.browser-pane", in: window)?.recordedFrame ?? .zero
            let detail = NativeUIAccessibility.find("inbox.detail-pane", in: window)?.recordedFrame ?? .zero
            let card = NativeUIAccessibility.find("inbox.row.\(cardID)", in: window)?.recordedFrame ?? .zero
            let valid =
                feed.width >= 299 && feed.width <= 421 && detail.width >= 350
                && card.width >= 240 && card.width <= feed.width && card.height >= 110
                && (key != "default" || abs(feed.width - 340) < 3)
                && feed.maxX <= detail.minX + 2 && selectedID(store) == cardID && store.section == .inbox
            results["layout-\(key)"] = valid ? "passed" : "failed: feed=\(feed) detail=\(detail) card=\(card)"
            results["geometry-\(key)"] = "feed=\(feed) detail=\(detail) card=\(card)"
        }
        private static func resizeFeed(store: DieterStore, window: NSWindow, results: inout [String: String]) async {
            guard let target = NativeUIAccessibility.find("inbox.browser-pane", in: window)?.object as? NSView else {
                results["feed-native-resize"] = "failed: feed anchor missing"; return
            }
            var ancestor = target.superview
            while let view = ancestor {
                if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2,
                    split.arrangedSubviews[0].frame.width <= 421
                {
                    let original = split.arrangedSubviews[0].frame.width
                    let selected = selectedID(store)
                    split.setPosition(400, ofDividerAt: 0)
                    let widened = await NativeUIAccessibility.wait {
                        abs(split.arrangedSubviews[0].frame.width - 400) < 3
                    }
                    split.setPosition(310, ofDividerAt: 0)
                    let narrowed = await NativeUIAccessibility.wait {
                        abs(split.arrangedSubviews[0].frame.width - 310) < 3
                    }
                    split.setPosition(original, ofDividerAt: 0)
                    record(
                        "feed-native-resize",
                        widened && narrowed && selectedID(store) == selected && store.section == .inbox, &results)
                    return
                }
                ancestor = view.superview
            }
            results["feed-native-resize"] = "failed: native feed split unavailable"
        }
        private static func captureAppearances(
            store: DieterStore, window: NSWindow, name: String, output: URL, results: inout [String: String]
        ) async {
            let defaults = DieterAppearance.applicationDefaults()
            let original = defaults.string(forKey: DieterAppearance.storageKey)
            defer {
                if let original {
                    defaults.set(original, forKey: DieterAppearance.storageKey)
                } else {
                    defaults.removeObject(forKey: DieterAppearance.storageKey)
                }
            }
            for appearance in [DieterAppearance.dark, .light] {
                defaults.set(appearance.rawValue, forKey: DieterAppearance.storageKey)
                let ready = await NativeUIAccessibility.wait {
                    store.themeSelection.appearance == appearance
                        && window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                            == (appearance == .dark ? .darkAqua : .aqua)
                }
                try? await DieterTaskSleep.milliseconds(350)
                let filename = "\(name)-\(appearance.rawValue).png"
                capture(window, filename, output)
                record(
                    "capture-\(name)-\(appearance.rawValue)",
                    ready && FileManager.default.fileExists(atPath: output.appending(path: filename).path), &results)
            }
        }
        private static func capture(_ window: NSWindow, _ name: String, _ output: URL) {
            NativeUISmokeRunner.capture(window, to: output.appending(path: name))
        }
        private static func record(_ name: String, _ passed: Bool, _ results: inout [String: String]) {
            results[name] = passed ? "passed" : "failed: observable Inbox contract not satisfied"
        }
        private static func finish(_ results: [String: String], output: URL) {
            let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: output.appending(path: "report.json"), options: .atomic)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
#endif
