import AppKit
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func floatingComposerKeepsLastMessageAboveInputAsDraftGrows() async throws {
    let store = DieterStore(liveEnvironment: false)
    var card = Dieter_V1_Card()
    card.id = "composer-layout"
    card.scope = "chat"
    card.title = "Composer layout"
    card.runtime = "idle"
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.detail.card = card
    snapshot.conversation.cardID = card.id
    snapshot.conversation.messages = (0..<12).map { index in
        var message = Dieter_V1_UiMessage()
        message.id = "layout-message-\(index)"
        message.role = index.isMultiple(of: 2) ? "user" : "assistant"
        var part = Dieter_V1_MessagePart()
        part.type = "text"
        part.text =
            index == 11
            ? "Last message must stay above the composer."
            : String(repeating: "A transcript line to fill the scroll view.\n", count: 5)
        message.parts = [part]
        return message
    }
    store.state.chats = [card]
    store.chats = [card]
    store.showChatsFixture()
    store.selectedChatID = card.id
    store.conversation = snapshot
    store.selectedDetail = snapshot.detail
    let root = NSHostingView(
        rootView: ConversationView(compact: true).environment(store).environment(store.conversationContext))
    root.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.borderless], backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    defer { window.close() }

    for draft in ["", "Line one\nLine two\nLine three\nLine four\nLine five", ""] {
        store.composerText = draft
        root.layoutSubtreeIfNeeded()
        try await DieterTaskSleep.milliseconds(350)
        root.layoutSubtreeIfNeeded()
        let views = composerLayoutViews(in: root)
        let scroll = try #require(
            views.compactMap { $0 as? NSScrollView }.first {
                ($0.documentView?.bounds.height ?? 0) > 1000
            })
        let lastMessage = try #require(
            views.compactMap { $0 as? NSTextView }.first {
                $0.string == "Last message must stay above the composer."
            })
        let composer = try #require(
            views.compactMap { $0 as? NSTextField }.first {
                $0.isEditable && $0.stringValue == draft
            })
        let scrollFrame = scroll.convert(scroll.bounds, to: root)
        let composerFrame = composer.convert(composer.bounds, to: root)
        let lastFrame = lastMessage.convert(lastMessage.bounds, to: root)
        let unobscuredBottom = scrollFrame.maxY - scroll.contentInsets.bottom
        let documentHeight = try #require(scroll.documentView?.bounds.height)

        // The transcript extends beneath the glass, while its tail stops above
        // the entire composer, even when the draft changes the reserved inset.
        #expect(abs(scrollFrame.maxY - root.bounds.maxY) < 1)
        #expect(scrollFrame.maxY > composerFrame.maxY)
        #expect(lastFrame.maxY <= unobscuredBottom)
        #expect(abs(scroll.documentVisibleRect.maxY - scroll.contentInsets.bottom - documentHeight) < 1)

    }
}

@MainActor private func composerLayoutViews(in root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { composerLayoutViews(in: $0) }
}

@Test @MainActor func composerTracksTheResizableConversationColumn() async throws {
    let store = DieterStore(liveEnvironment: false)
    var card = Dieter_V1_Card()
    card.id = "composer-resize"
    card.scope = "chat"
    card.title = "Resizable composer"
    card.runtime = "idle"
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.detail.card = card
    snapshot.conversation.cardID = card.id
    store.state.chats = [card]
    store.chats = [card]
    store.selectedChatID = card.id
    store.conversation = snapshot
    store.selectedDetail = snapshot.detail

    let content = store.conversationContext.content
    content.currentEndpointID = { _ in "composer-resize-endpoint" }
    content.showEmpty(conversationID: card.id)
    #expect(await waitForComposerLayout { content.isPresented(for: card.id) })

    let root = NSHostingView(
        rootView: ConversationView(compact: true).environment(store).environment(store.conversationContext))
    root.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: -3_000, y: -3_000, width: 1_000, height: 680),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    window.orderBack(nil)
    defer { window.close() }

    let mounted = await waitForComposerLayout {
        root.layoutSubtreeIfNeeded()
        guard let split = composerWorkspaceSplit(in: root), composerTextField(in: root) != nil else { return false }
        let available = split.bounds.width - split.dividerThickness
        return abs(
            split.arrangedSubviews[0].frame.width
                - available * ConversationContentSizing.conversationFraction) < 2
    }
    #expect(mounted)
    let split = try #require(composerWorkspaceSplit(in: root))
    let field = try #require(composerTextField(in: root))

    split.setPosition(520, ofDividerAt: 0)
    split.layoutSubtreeIfNeeded()
    let wide = await waitForComposerLayout {
        root.layoutSubtreeIfNeeded()
        return abs(split.arrangedSubviews[0].frame.width - 520) < 2
            && field.convert(field.bounds, to: root).width > 450
    }
    #expect(wide)
    let wideFieldWidth = field.convert(field.bounds, to: root).width

    split.setPosition(380, ofDividerAt: 0)
    split.layoutSubtreeIfNeeded()
    let narrow = await waitForComposerLayout {
        root.layoutSubtreeIfNeeded()
        let fieldFrame = field.convert(field.bounds, to: root)
        let chatFrame = split.arrangedSubviews[0].convert(split.arrangedSubviews[0].bounds, to: root)
        return abs(split.arrangedSubviews[0].frame.width - 380) < 2
            && fieldFrame.width < wideFieldWidth - 100
            && chatFrame.insetBy(dx: -1, dy: -1).contains(fieldFrame)
    }
    #expect(narrow)
}

@MainActor private func composerWorkspaceSplit(in root: NSView) -> NSSplitView? {
    composerLayoutViews(in: root).compactMap { $0 as? NSSplitView }.first {
        $0.accessibilityIdentifier() == "conversation.workspace-split"
    }
}

@MainActor private func composerTextField(in root: NSView) -> NSTextField? {
    composerLayoutViews(in: root).compactMap { $0 as? NSTextField }.first {
        $0.isEditable && $0.placeholderString == "Message the local agent…"
    }
}

@MainActor private func waitForComposerLayout(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

@Test @MainActor func allChatsKeepsComposerInsideWindowBelowTheTitlebar() async throws {
    let store = DieterStore(liveEnvironment: false)
    var project = Dieter_V1_Project()
    project.id = "layout-project"
    project.name = "Layout fixture"
    var card = Dieter_V1_Card()
    card.id = "layout-draft"
    card.projectID = project.id
    card.scope = "chat"
    card.title = "Saved chat awaiting its first turn"
    card.initialPrompt = "The draft remains visible when admission fails."
    card.runtime = "idle"
    card.workspaceMode = "project"
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.detail.card = card
    snapshot.detail.project = project
    snapshot.conversation.cardID = card.id
    store.projectDirectory = [project.id: project]
    store.projectReplicaEndpointIDs = [project.id: store.endpoint.id]
    store.state.chats = [card]
    store.chats = [card]
    store.selectedChatID = card.id
    store.selectedDetail = snapshot.detail
    store.conversation = snapshot

    let root = NSHostingView(
        rootView: ChatsView().environment(store).preferredColorScheme(.dark)
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 44) })
    root.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    defer { window.close() }

    for height in [680, 820] {
        window.setContentSize(NSSize(width: 1100, height: height))
        for draft in ["", "First line\nSecond line\nThird line\nFourth line\nFifth line"] {
            store.composerText = draft
            root.layoutSubtreeIfNeeded()
            try await DieterTaskSleep.milliseconds(250)
            root.layoutSubtreeIfNeeded()
            let composer = try #require(
                composerLayoutViews(in: root).compactMap { $0 as? NSTextField }.first {
                    $0.isEditable && $0.placeholderString == "Message the local agent…"
                })
            let frame = composer.convert(composer.bounds, to: root)
            #expect(root.bounds.contains(frame), "Composer \(frame) exceeds window \(root.bounds)")
            // Leave room for the attachment/model/send toolbar under the editor.
            #expect(frame.maxY <= root.bounds.maxY - 38, "Composer toolbar is clipped below the window")
        }
    }
    if let output = ProcessInfo.processInfo.environment["DIETER_COMPOSER_LAYOUT_OUTPUT"], !output.isEmpty {
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
