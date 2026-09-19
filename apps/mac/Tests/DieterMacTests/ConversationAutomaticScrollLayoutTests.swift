import AppKit
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func automaticHistoryScrollLoadsOnePageAndPreservesTheReaderThroughNetworkDelay() async throws {
    let rpc = AutomaticScrollLayoutRPC()
    let store = DieterStore(restoreSync: false)
    let context = store.conversationContext
    let model = context.model
    let snapshot = automaticScrollSnapshot(start: 90, end: 120)
    store.state.chats = [snapshot.detail.card]
    store.chats = [snapshot.detail.card]
    store.selectedChatID = snapshot.detail.card.id
    store.conversation = snapshot
    store.selectedDetail = snapshot.detail
    model.resetConversationHistory(from: snapshot)
    model.bind(client: rpc, endpointID: "automatic-scroll-layout")
    context.onLoadEarlierMessages = { await model.loadEarlierMessages() }

    let root = NSHostingView(
        rootView: ConversationTimeline().environment(store).environment(context))
    root.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    defer {
        model.bind(client: nil, endpointID: "automatic-scroll-layout")
        Task { await rpc.releasePage() }
        window.close()
    }

    await settleAutomaticScroll(root, milliseconds: 350)
    let scroll = try #require(
        automaticScrollViews(in: root).compactMap { $0 as? NSScrollView }.first {
            ($0.documentView?.bounds.height ?? 0) > 1_000
        })
    #expect(await rpc.requestCount == 0, "Opening at the live tail must not load older pages")
    #expect(
        abs(
            scroll.documentVisibleRect.maxY - scroll.contentInsets.bottom
                - (scroll.documentView?.bounds.maxY ?? 0)) < 2)

    // Deliver native wheel events directly to this hidden fixture's scroll
    // view. No global input, key window, operator app, or daemon is involved.
    for index in 0..<100 {
        try automaticScrollWheel(scroll, window: window, pixels: 64, phase: index == 0 ? 1 : 2)
        await settleAutomaticScroll(root, milliseconds: 20)
        if await rpc.requestCount > 0 { break }
    }
    try #require(await rpc.requestCount == 1, "Scrolling to the earlier edge must request one page")
    try #require(model.conversationHistoryLoading)

    // The user keeps scrolling while the network is outstanding. Restoring
    // the anchor captured at request start would undo this newer movement.
    for _ in 0..<2 {
        try automaticScrollWheel(scroll, window: window, pixels: 28, phase: 2)
        await settleAutomaticScroll(root, milliseconds: 20)
    }
    try automaticScrollWheel(scroll, window: window, pixels: 0, phase: 4)
    await settleAutomaticScroll(root, milliseconds: 80)
    let reading = try #require(automaticScrollReadingPosition(in: scroll))

    await rpc.releasePage()
    for _ in 0..<40 {
        await settleAutomaticScroll(root, milliseconds: 20)
        if !model.conversationHistoryLoading,
            automaticScrollTextPosition(reading.text, in: scroll) != nil,
            model.olderConversationMessages.count == 30
        {
            break
        }
    }
    await settleAutomaticScroll(root, milliseconds: 160)
    let restoredOffset = try #require(automaticScrollTextPosition(reading.text, in: scroll))
    #expect(abs(restoredOffset - reading.offset) < 2, "Loading must preserve the current message's pixel offset")
    #expect(model.olderConversationMessages.count == 30)
    #expect(await rpc.requestCount == 1, "A restored viewport must not chain-load another page")

    // Scrolling down through the loaded conversation rejoins the live tail
    // and releases the accumulated history without a later-page button.
    for index in 0..<100 {
        try automaticScrollWheel(scroll, window: window, pixels: -96, phase: index == 0 ? 1 : 2)
        await settleAutomaticScroll(root, milliseconds: 20)
        if model.olderConversationMessages.isEmpty { break }
    }
    try automaticScrollWheel(scroll, window: window, pixels: 0, phase: 4)
    await settleAutomaticScroll(root, milliseconds: 160)
    #expect(model.olderConversationMessages.isEmpty)
    #expect(!model.browsingEarlierHistory)
    #expect(model.conversationMessages.map(\.id) == snapshot.conversation.messages.map(\.id))
    #expect(
        abs(
            scroll.documentVisibleRect.maxY - scroll.contentInsets.bottom
                - (scroll.documentView?.bounds.maxY ?? 0)) < 2)
    #expect(await rpc.requestCount == 1)
}

@Test @MainActor func automaticHistoryDownwardWheelAdvancesFromABoundedRenderedEnd() async throws {
    let store = DieterStore(restoreSync: false)
    let context = store.conversationContext
    var snapshot = automaticScrollSnapshot(start: 90, end: 120)
    for index in snapshot.conversation.messages.indices {
        snapshot.conversation.messages[index].parts[0].text =
            "Automatic scroll message \(index + 90).\n"
            + String(
                repeating: "A longer transcript line keeps rendering bounded while preserving useful content.\n",
                count: 16)
    }
    store.state.chats = [snapshot.detail.card]
    store.chats = [snapshot.detail.card]
    store.selectedChatID = snapshot.detail.card.id
    store.conversation = snapshot
    store.selectedDetail = snapshot.detail
    context.model.resetConversationHistory(from: snapshot)
    context.onLoadEarlierMessages = { false }
    let root = NSHostingView(
        rootView: ConversationTimeline().environment(store).environment(context))
    root.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    defer { window.close() }
    await settleAutomaticScroll(root, milliseconds: 350)
    let scroll = try #require(
        automaticScrollViews(in: root).compactMap { $0 as? NSScrollView }.first {
            ($0.documentView?.bounds.height ?? 0) > 1_000
        })
    let initialIDs = automaticScrollRenderedMessageIDs(in: scroll)
    try #require(initialIDs.contains(119))
    try #require(initialIDs.count < snapshot.conversation.messages.count, "The fixture must exceed the render budget")

    for index in 0..<160 {
        try automaticScrollWheel(scroll, window: window, pixels: 96, phase: index == 0 ? 1 : 2)
        await settleAutomaticScroll(root, milliseconds: 20)
        if !automaticScrollRenderedMessageIDs(in: scroll).contains(119) { break }
    }
    try automaticScrollWheel(scroll, window: window, pixels: 0, phase: 4)
    await settleAutomaticScroll(root, milliseconds: 160)
    let earlierIDs = automaticScrollRenderedMessageIDs(in: scroll)
    try #require(!earlierIDs.contains(119), "Earlier scrolling must replace the bounded live render window")
    try #require((earlierIDs.min() ?? 120) < (initialIDs.min() ?? 0))

    // A page restoration can land at the exact rendered bottom while newer
    // messages remain outside this window. Put the native scrollbar there:
    // further down-wheel intent must advance even when the offset cannot move.
    for _ in 0..<20 {
        let document = try #require(scroll.documentView)
        var bounds = scroll.contentView.bounds
        bounds.origin.y = document.bounds.maxY - bounds.height + scroll.contentInsets.bottom
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        await settleAutomaticScroll(root, milliseconds: 40)
        #expect(
            abs(scroll.documentVisibleRect.maxY - scroll.contentInsets.bottom - document.bounds.maxY) < 2,
            "The next wheel gesture must start at a clamped rendered edge")

        try automaticScrollWheel(scroll, window: window, pixels: -64, phase: 1)
        await settleAutomaticScroll(root, milliseconds: 40)
        try automaticScrollWheel(scroll, window: window, pixels: 0, phase: 4)
        await settleAutomaticScroll(root, milliseconds: 120)
        if automaticScrollRenderedMessageIDs(in: scroll).contains(119) { break }
    }
    #expect(
        automaticScrollRenderedMessageIDs(in: scroll).contains(119),
        "Downward wheel intent at a bounded page's bottom must make the true latest message reachable")
}

@Test @MainActor func automaticLongConversationScrollNeverReversesItsRenderWindow() async throws {
    let store = DieterStore(restoreSync: false)
    let context = store.conversationContext
    var snapshot = automaticScrollSnapshot(start: 0, end: 120)
    for index in snapshot.conversation.messages.indices {
        snapshot.conversation.messages[index].parts[0].text =
            "Automatic scroll message \(index).\n"
            + String(
                repeating: "Long transcript content keeps each bounded render window deliberately small.\n",
                count: 10)
    }
    snapshot.page.hasMore_p = false
    store.state.chats = [snapshot.detail.card]
    store.chats = [snapshot.detail.card]
    store.selectedChatID = snapshot.detail.card.id
    store.conversation = snapshot
    store.selectedDetail = snapshot.detail
    context.model.resetConversationHistory(from: snapshot)
    context.onLoadEarlierMessages = { false }

    let root = NSHostingView(
        rootView: ConversationTimeline().environment(store).environment(context))
    root.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    defer { window.close() }

    await settleAutomaticScroll(root, milliseconds: 350)
    let scroll = try #require(
        automaticScrollViews(in: root).compactMap { $0 as? NSScrollView }.first {
            ($0.documentView?.bounds.height ?? 0) > 1_000
        })
    var windows: [ClosedRange<Int>] = []
    var visibleMessages: [Int] = []

    for index in 0..<140 {
        try automaticScrollWheel(scroll, window: window, pixels: 160, phase: index == 0 ? 1 : 2)
        await settleAutomaticScroll(root, milliseconds: 10)
        let ids = automaticScrollRenderedMessageIDs(in: scroll)
        if let lower = ids.min(), let upper = ids.max() {
            let range = lower...upper
            if windows.last != range { windows.append(range) }
        }
        if let visible = automaticScrollVisibleMessageID(in: scroll), visibleMessages.last != visible {
            visibleMessages.append(visible)
        }
        if windows.last?.lowerBound == 0 { break }
    }
    try automaticScrollWheel(scroll, window: window, pixels: 0, phase: 4)
    await settleAutomaticScroll(root, milliseconds: 160)

    try #require(windows.count >= 3, "The fixture must traverse multiple bounded render windows: \(windows)")
    for (previous, current) in zip(windows, windows.dropFirst()) {
        #expect(
            current.lowerBound <= previous.lowerBound,
            "Earlier-only wheel input paged later: \(windows)")
    }
    for (previous, current) in zip(visibleMessages, visibleMessages.dropFirst()) {
        #expect(
            current <= previous,
            "Earlier-only wheel input moved the visible transcript forward: \(visibleMessages)")
    }
    let firstWindow = try #require(windows.first)
    let lastWindow = try #require(windows.last)
    #expect(
        lastWindow.lowerBound <= firstWindow.lowerBound - 24,
        "The gesture must make substantial progress through the long transcript: \(windows)")
}

private actor AutomaticScrollLayoutRPC: ConversationRPC {
    private var pending: CheckedContinuation<Dieter_V1_ConversationSnapshot, Never>?
    private var requestedBefore = 0
    private(set) var requestCount = 0

    func conversation(cardID: String, limit: Int32, before: Int32?) async throws -> Dieter_V1_ConversationSnapshot {
        requestedBefore = Int(before ?? 120)
        requestCount += 1
        return await withCheckedContinuation { pending = $0 }
    }

    func releasePage() {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: automaticScrollSnapshot(start: max(0, requestedBefore - 30), end: requestedBefore))
    }

    func watchConversation(
        cardID: String, after: Int64, receive: @escaping @Sendable (Dieter_V1_ConversationUpdate) async -> Void
    ) async throws {}
}

private func automaticScrollSnapshot(start: Int, end: Int) -> Dieter_V1_ConversationSnapshot {
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.detail.card.id = "automatic-scroll-layout"
    snapshot.detail.card.scope = "chat"
    snapshot.detail.card.title = "Automatic history layout"
    snapshot.detail.card.runtime = "idle"
    snapshot.conversation.cardID = snapshot.detail.card.id
    snapshot.conversation.messages = (start..<end).map { index in
        var message = Dieter_V1_UiMessage()
        message.id = "automatic-scroll-message-\(index)"
        message.role = "assistant"
        var part = Dieter_V1_MessagePart()
        part.type = "text"
        part.text =
            "Automatic scroll message \(index).\nA second line keeps this transcript tall.\nA third line marks the reading position."
        message.parts = [part]
        return message
    }
    snapshot.page.start = Int32(start)
    snapshot.page.end = Int32(end)
    snapshot.page.total = 120
    snapshot.page.hasMore_p = start > 0
    return snapshot
}

@MainActor private func automaticScrollWheel(
    _ scroll: NSScrollView, window: NSWindow, pixels: Int32, phase: Int64, momentum: Int64 = 0
) throws {
    let event = try #require(
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0))
    let screen = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
    event.location = NSPoint(x: screen.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.midY)
    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
    event.setIntegerValueField(
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    let nativeEvent = try #require(NSEvent(cgEvent: event))
    if let content = window.contentView {
        for monitor in automaticScrollViews(in: content).compactMap({ $0 as? ConversationScrollIntentProbe.MonitorView }
        ) {
            // Direct fixture dispatch bypasses NSApplication's local event
            // monitors, so deliver to the same production handler explicitly.
            monitor.handleScrollEvent(nativeEvent)
        }
    }
    scroll.scrollWheel(with: nativeEvent)
}

@MainActor private func automaticScrollReadingPosition(in scroll: NSScrollView) -> (text: String, offset: CGFloat)? {
    guard let document = scroll.documentView else { return nil }
    let viewport = scroll.contentView.bounds
    return automaticScrollViews(in: document).compactMap { view -> (String, CGFloat)? in
        guard let text = view as? NSTextView, text.string.hasPrefix("Automatic scroll message ") else { return nil }
        let frame = text.convert(text.bounds, to: document)
        guard frame.maxY > viewport.minY, frame.minY < viewport.maxY else { return nil }
        return (text.string, frame.minY - viewport.minY)
    }.min { $0.1 < $1.1 }
}

@MainActor private func automaticScrollTextPosition(_ text: String, in scroll: NSScrollView) -> CGFloat? {
    guard let document = scroll.documentView,
        let view = automaticScrollViews(in: document).compactMap({ $0 as? NSTextView }).first(where: {
            $0.string == text
        })
    else { return nil }
    return view.convert(view.bounds, to: document).minY - scroll.contentView.bounds.minY
}

@MainActor private func automaticScrollRenderedMessageIDs(in scroll: NSScrollView) -> Set<Int> {
    guard let document = scroll.documentView else { return [] }
    return Set(
        automaticScrollViews(in: document).compactMap { view -> Int? in
            guard let text = view as? NSTextView, text.string.hasPrefix("Automatic scroll message "),
                let firstSentence = text.string.split(separator: ".", maxSplits: 1).first,
                let lastWord = firstSentence.split(separator: " ").last
            else { return nil }
            return Int(lastWord)
        })
}

@MainActor private func automaticScrollVisibleMessageID(in scroll: NSScrollView) -> Int? {
    guard let reading = automaticScrollReadingPosition(in: scroll),
        let firstSentence = reading.text.split(separator: ".", maxSplits: 1).first,
        let lastWord = firstSentence.split(separator: " ").last
    else { return nil }
    return Int(lastWord)
}

@MainActor private func automaticScrollViews(in root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { automaticScrollViews(in: $0) }
}

@MainActor private func settleAutomaticScroll(_ root: NSView, milliseconds: Int) async {
    root.layoutSubtreeIfNeeded()
    try? await DieterTaskSleep.milliseconds(milliseconds)
    root.layoutSubtreeIfNeeded()
}

@Test @MainActor func automaticTailWheelAndMomentumDoNotScheduleCorrections() async throws {
    let fixture = TailGestureFixture()
    defer { fixture.window.close() }
    await settleAutomaticScroll(fixture.root, milliseconds: 350)
    let scroll = try fixture.scroll()
    let initialCorrections = fixture.tailCorrections
    for index in 0..<20 {
        try automaticScrollWheel(scroll, window: fixture.window, pixels: -12, phase: index == 0 ? 1 : 2)
        await settleAutomaticScroll(fixture.root, milliseconds: 10)
    }
    try automaticScrollWheel(scroll, window: fixture.window, pixels: 0, phase: 4)
    for index in 0..<12 {
        try automaticScrollWheel(
            scroll, window: fixture.window, pixels: -4, phase: 0, momentum: index == 0 ? 1 : 2)
        await settleAutomaticScroll(fixture.root, milliseconds: 10)
    }
    try automaticScrollWheel(scroll, window: fixture.window, pixels: 0, phase: 0, momentum: 4)
    await settleAutomaticScroll(fixture.root, milliseconds: 120)
    #expect(fixture.tailCorrections == initialCorrections, "Native bottom bounce must not trigger tail corrections")
    #expect(!fixture.jumpVisible)
    #expect(fixture.detachTransitions == 0, "Bottom input must never flash Jump to latest")
    #expect(
        abs(
            scroll.documentVisibleRect.maxY - scroll.contentInsets.bottom
                - (scroll.documentView?.bounds.maxY ?? 0)) < 2)
}

@Test @MainActor func automaticUpwardIntentWinsOverStreamingAndMomentum() async throws {
    let fixture = TailGestureFixture()
    defer { fixture.window.close() }
    await settleAutomaticScroll(fixture.root, milliseconds: 350)
    let scroll = try fixture.scroll()
    let initialCorrections = fixture.tailCorrections
    // Queue content growth immediately before input, without allowing the tail
    // task to settle first. The event monitor must invalidate that pending work.
    fixture.appendText()
    try automaticScrollWheel(scroll, window: fixture.window, pixels: 1, phase: 1)
    await settleAutomaticScroll(fixture.root, milliseconds: 20)
    #expect(fixture.jumpVisible, "Even a small upward gesture relinquishes tail following")
    var previous = scroll.contentView.bounds.minY
    for index in 0..<12 {
        fixture.appendText()
        try automaticScrollWheel(
            scroll, window: fixture.window, pixels: 12, phase: index < 6 ? 2 : 0,
            momentum: index < 6 ? 0 : (index == 6 ? 1 : 2))
        await settleAutomaticScroll(fixture.root, milliseconds: 20)
        let current = scroll.contentView.bounds.minY
        #expect(current <= previous + 2, "Upward input must not snap toward newer content")
        previous = current
    }
    try automaticScrollWheel(scroll, window: fixture.window, pixels: 0, phase: 4, momentum: 4)
    await settleAutomaticScroll(fixture.root, milliseconds: 120)
    let reading = try #require(automaticScrollReadingPosition(in: scroll))
    fixture.appendText()
    await settleAutomaticScroll(fixture.root, milliseconds: 120)
    let position = try #require(automaticScrollTextPosition(reading.text, in: scroll))
    #expect(abs(position - reading.offset) < 2)
    #expect(fixture.tailCorrections == initialCorrections)
    #expect(fixture.jumpVisible)
}

@MainActor private final class TailGestureFixture {
    let store = DieterStore(restoreSync: false)
    let window: NSWindow
    var root: NSView { window.contentView! }
    var tailCorrections = 0
    var jumpVisible = false
    var detachTransitions = 0

    init() {
        var snapshot = automaticScrollSnapshot(start: 0, end: 30)
        snapshot.page.hasMore_p = false
        store.state.chats = [snapshot.detail.card]
        store.chats = [snapshot.detail.card]
        store.selectedChatID = snapshot.detail.card.id
        store.conversation = snapshot
        store.selectedDetail = snapshot.detail
        store.conversationContext.model.resetConversationHistory(from: snapshot)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(
            rootView:
                ConversationTimeline(
                    onTailScroll: { [weak self] in self?.tailCorrections += 1 },
                    onViewportObservation: { [weak self] observation in
                        guard let self else { return }
                        if !observation.followsLatest && !jumpVisible { detachTransitions += 1 }
                        jumpVisible = !observation.followsLatest
                    }
                )
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 100) }
                .environment(store).environment(store.conversationContext))
        root.sizingOptions = []
        window.contentView = root
    }

    func scroll() throws -> NSScrollView {
        try #require(
            automaticScrollViews(in: root).compactMap { $0 as? NSScrollView }.first {
                ($0.documentView?.bounds.height ?? 0) > 1_000
            })
    }

    func appendText() {
        var snapshot = store.conversation!
        snapshot.conversation.messages[29].parts[0].text += "\nStreaming content grows at the tail."
        store.conversation = snapshot
    }
}

@Test @MainActor func automaticFollowingSurvivesContentGrowthAndViewportResize() async throws {
    let fixture = TailGestureFixture()
    defer { fixture.window.close() }
    await settleAutomaticScroll(fixture.root, milliseconds: 350)
    let scroll = try fixture.scroll()
    fixture.appendText()
    await settleAutomaticScroll(fixture.root, milliseconds: 150)
    #expect(
        abs(
            scroll.documentVisibleRect.maxY - scroll.contentInsets.bottom
                - (scroll.documentView?.bounds.maxY ?? 0)) < 2)
    fixture.window.setContentSize(NSSize(width: 560, height: 420))
    await settleAutomaticScroll(fixture.root, milliseconds: 150)
    #expect(
        abs(
            scroll.documentVisibleRect.maxY - scroll.contentInsets.bottom
                - (scroll.documentView?.bounds.maxY ?? 0)) < 2)
    #expect(!fixture.jumpVisible)
}

@Test @MainActor func automaticPhaselessWheelDetachesAndCanRejoinLatest() async throws {
    let fixture = TailGestureFixture()
    defer { fixture.window.close() }
    await settleAutomaticScroll(fixture.root, milliseconds: 350)
    let scroll = try fixture.scroll()
    let bottom = scroll.contentView.bounds.minY
    try automaticScrollWheel(scroll, window: fixture.window, pixels: 100, phase: 0)
    await settleAutomaticScroll(fixture.root, milliseconds: 80)
    #expect(scroll.contentView.bounds.minY < bottom - 2)
    #expect(fixture.jumpVisible)
    for _ in 0..<10 {
        try automaticScrollWheel(scroll, window: fixture.window, pixels: -100, phase: 0)
        await settleAutomaticScroll(fixture.root, milliseconds: 20)
    }
    await settleAutomaticScroll(fixture.root, milliseconds: 80)
    #expect(!fixture.jumpVisible)
    #expect(
        abs(
            scroll.documentVisibleRect.maxY - scroll.contentInsets.bottom
                - (scroll.documentView?.bounds.maxY ?? 0)) < 2)
}
