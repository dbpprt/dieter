import AppKit
import DieterAPI
import SharedCore
import SwiftUI
import Testing
@testable import DieterMac

@Test(arguments: [false, true], [false, true]) @MainActor
func initialTranscriptMountsOnlyTheTailAndExpandsToFillShortRows(shortRows: Bool, chat: Bool) async throws {
    let store = DieterStore(liveEnvironment: false)
    var snapshot = automaticScrollSnapshot(start: 0, end: 30)
    for index in snapshot.conversation.messages.indices {
        snapshot.conversation.messages[index].parts[0].text =
            "Automatic scroll message \(index)."
            + (shortRows ? "" : String(repeating: "\nA rich transcript line to lay out.", count: 8))
    }
    if chat {
        store.state.chats = [snapshot.detail.card]
        store.chats = [snapshot.detail.card]
        store.selectedChatID = snapshot.detail.card.id
    } else {
        snapshot.detail.card.scope = "board"
        store.selectedCardID = snapshot.detail.card.id
    }
    store.conversation = snapshot
    store.selectedDetail = snapshot.detail
    let context = store.conversationContext
    context.model.resetHistory(to: snapshot)
    var historyRequests = 0
    context.onLoadEarlierMessages = {
        historyRequests += 1; return false
    }
    var positioned = false
    var ready = false
    let root = NSHostingView(
        rootView: ConversationTimeline(
            onViewportObservation: { positioned = $0.initialPositionComplete },
            onReadinessChange: { ready = $0 }
        )
        .environment(store).environment(context))
    root.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: chat ? 700 : 420, height: 600),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    defer { window.contentView = nil; window.close() }
    let committed = CommittedFrameSampler {
        guard ready, let scroll = automaticScrollViews(in: root).compactMap({ $0 as? NSScrollView }).first,
            let document = scroll.documentView
        else { return nil }
        return abs(scroll.documentVisibleRect.maxY - scroll.contentInsets.bottom - document.bounds.maxY)
    }
    for _ in 0..<100 {
        await settleAutomaticScroll(root, milliseconds: 20)
        if positioned { break }
    }
    #expect(positioned)
    #expect(ready)
    #expect(committed.stop() < 2, "Every revealed frame must already be positioned at the tail")
    let scroll = try #require(automaticScrollViews(in: root).compactMap { $0 as? NSScrollView }.first)
    let ids = automaticScrollRenderedMessageIDs(in: scroll)
    #expect(ids.contains(29))
    if shortRows {
        #expect(
            ids.count > ConversationRenderWindow.initialMessages,
            "Short rows must expand automatically instead of leaving the viewport half empty")
    } else {
        #expect(
            ids.count == ConversationRenderWindow.initialMessages,
            "Opening must not eagerly create every loaded rich message")
    }
    #expect((scroll.documentView?.bounds.height ?? 0) >= scroll.contentView.bounds.height)
    #expect(abs(scroll.documentVisibleRect.maxY - (scroll.documentView?.bounds.maxY ?? 0)) < 2)
    #expect(historyRequests == 0)
    #expect(context.conversationMessages.count == 30, "Rendering must preserve the loaded history")
}

@Test(arguments: [false, true]) @MainActor
func openingWaitsForLayoutAndCancelsThePreviousConversation(chat: Bool) async throws {
    let store = DieterStore(liveEnvironment: false)
    var snapshot = automaticScrollSnapshot(start: 0, end: 30)
    if !chat { snapshot.detail.card.scope = "board" }
    if chat { store.selectedChatID = snapshot.detail.card.id } else { store.selectedCardID = snapshot.detail.card.id }
    store.conversation = snapshot
    store.selectedDetail = snapshot.detail
    store.conversationContext.model.resetHistory(to: snapshot)
    var ready = false
    var positionedIDs: [String] = []
    let root = NSHostingView(
        rootView: ConversationTimeline(
            onViewportObservation: { if $0.initialPositionComplete { positionedIDs.append($0.conversationID) } },
            onReadinessChange: { ready = $0 }
        )
        .environment(store).environment(store.conversationContext))
    root.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: chat ? 700 : 420, height: 0),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    defer { window.contentView = nil; window.close() }
    await settleAutomaticScroll(root, milliseconds: 250)
    #expect(!ready, "An unusable viewport must stay hidden after the former opening timeout")
    #expect(positionedIDs.isEmpty)

    var replacement = automaticScrollSnapshot(start: 60, end: 90)
    replacement.detail.card.id = "replacement-conversation"
    replacement.detail.card.scope = snapshot.detail.card.scope
    replacement.conversation.cardID = replacement.detail.card.id
    if chat {
        store.selectedChatID = replacement.detail.card.id
    } else {
        store.selectedCardID = replacement.detail.card.id
    }
    store.conversation = replacement
    store.selectedDetail = replacement.detail
    store.conversationContext.model.resetHistory(to: replacement)
    window.setContentSize(NSSize(width: chat ? 700 : 420, height: 600))
    for _ in 0..<100 {
        await settleAutomaticScroll(root, milliseconds: 20)
        if ready { break }
    }
    #expect(ready)
    #expect(!positionedIDs.isEmpty)
    #expect(positionedIDs.allSatisfy { $0 == replacement.detail.card.id })
    let scroll = try #require(automaticScrollViews(in: root).compactMap { $0 as? NSScrollView }.first)
    let ids = automaticScrollRenderedMessageIDs(in: scroll)
    #expect(ids.contains(89))
    #expect(ids.allSatisfy { $0 >= 60 }, "A canceled opening must not mount the previous conversation")
    #expect(abs(scroll.documentVisibleRect.maxY - (scroll.documentView?.bounds.maxY ?? 0)) < 2)
}

@Test(arguments: [false, true]) @MainActor
func automaticHistoryLoadPreservesTheReaderThroughNetworkDelay(chat: Bool) async throws {
    // This page reaches the beginning, so the history control disappears
    // after its loading state without shifting the transcript.
    var snapshot = automaticScrollSnapshot(start: 60, end: 90)
    if !chat { snapshot.detail.card.scope = "board" }
    let rpc = AutomaticScrollLayoutCore(snapshot)
    let store = DieterStore(core: rpc.core, liveEnvironment: false)
    let context = store.conversationContext
    let model = context.model
    store.state.chats = [snapshot.detail.card]
    store.chats = [snapshot.detail.card]
    if chat { store.selectedChatID = snapshot.detail.card.id } else { store.selectedCardID = snapshot.detail.card.id }
    model.observe(snapshot.detail.card.id)
    rpc.publish()
    context.onLoadEarlierMessages = { await model.loadEarlierMessages() }

    var actions: ConversationHistoryActions?
    let root = NSHostingView(
        rootView: ConversationTimeline(onHistoryActions: { actions = $0 }).environment(store).environment(context))
    root.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: chat ? 700 : 420, height: 600),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    defer {
        actions = nil
        model.observe(nil)
        rpc.releasePage()
        window.close()
    }

    await settleAutomaticScroll(root, milliseconds: 350)
    let scroll = try #require(
        automaticScrollViews(in: root).compactMap { $0 as? NSScrollView }.first {
            ($0.documentView?.bounds.height ?? 0)
                > $0.contentView.bounds.height - $0.contentInsets.top - $0.contentInsets.bottom
        })
    #expect(rpc.requestCount == 0, "Opening at the live tail must not load older pages")
    #expect(
        abs(
            scroll.documentVisibleRect.maxY - scroll.contentInsets.bottom
                - (scroll.documentView?.bounds.maxY ?? 0)) < 2)

    let controls = try #require(actions)
    // Native scrolling first mounts the already loaded rows, then requests
    // the next core page without a click on the history control.
    for index in 0..<100 {
        try automaticScrollWheel(scroll, window: window, pixels: 64, phase: index == 0 ? 1 : 2)
        await settleAutomaticScroll(root, milliseconds: 20)
        if rpc.requestCount > 0 { break }
    }
    try #require(rpc.requestCount == 1, "Scrolling to earlier history must request a page automatically")
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
    // Every frame handed to the window server must already show the reader's
    // text where it was; a correction one frame later is visible flicker.
    let committed = CommittedFrameSampler {
        automaticScrollTextPosition(reading.text, in: scroll).map { abs($0 - reading.offset) }
    }

    #expect(rpc.requestCount == 1, "Continued scrolling while loading must not request another page")
    rpc.releasePage()
    for _ in 0..<40 {
        await settleAutomaticScroll(root, milliseconds: 20)
        if !model.conversationHistoryLoading,
            automaticScrollTextPosition(reading.text, in: scroll) != nil,
            model.olderConversationMessages.count == 60
        {
            break
        }
    }
    try await waitForAutomaticHistoryLayout(controls, root: root)
    await settleAutomaticScroll(root, milliseconds: 160)
    let restoredOffset = try #require(automaticScrollTextPosition(reading.text, in: scroll))
    #expect(abs(restoredOffset - reading.offset) < 2, "Loading must preserve the current message's pixel offset")
    #expect(committed.stop() < 2, "No committed frame may show the transcript displaced by the loaded page")
    #expect(model.olderConversationMessages.count == 60)
    #expect(!model.conversationHistoryHasMore)
    #expect(rpc.requestCount == 1, "A restored viewport must not chain-load another page")

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
    #expect(rpc.requestCount == 1)
}

@Test(arguments: [false, true]) @MainActor
func automaticHistoryPagingKeepsEveryCommittedFrameAnchored(chat: Bool) async throws {
    let store = DieterStore(liveEnvironment: false)
    let context = store.conversationContext
    var snapshot = automaticScrollSnapshot(start: 0, end: 360)
    for index in snapshot.conversation.messages.indices {
        snapshot.conversation.messages[index].parts[0].text =
            "Automatic scroll message \(index).\n"
            + String(repeating: "A rich transcript line keeps the render budget small.\n", count: 16)
    }
    snapshot.page.hasMore_p = false
    if chat {
        store.selectedChatID = snapshot.detail.card.id
    } else {
        snapshot.detail.card.scope = "board"
        store.selectedCardID = snapshot.detail.card.id
    }
    store.conversation = snapshot
    store.selectedDetail = snapshot.detail
    context.model.resetHistory(to: snapshot)
    context.onLoadEarlierMessages = { false }
    var actions: ConversationHistoryActions?
    let root = NSHostingView(
        rootView: ConversationTimeline(onHistoryActions: { actions = $0 })
            .environment(store).environment(context))
    root.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: chat ? 700 : 420, height: 600),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    defer { actions = nil; window.contentView = nil; window.close() }
    await settleAutomaticScroll(root, milliseconds: 350)
    let scroll = try #require(automaticScrollViews(in: root).compactMap { $0 as? NSScrollView }.first)
    let controls = try #require(actions)
    var ranges: [ClosedRange<Int>] = []
    for _ in 0..<4 {
        // Deliver input before moving the native clip, as AppKit does. A raw
        // clip jump can be treated as layout while a previous page's reading
        // position is still held, especially on faster CI workers.
        try automaticScrollWheelToEdge(scroll, window: window, earlier: true)
        let reading = try #require(automaticScrollReadingPosition(in: scroll))
        let committed = CommittedFrameSampler {
            automaticScrollTextPosition(reading.text, in: scroll).map { abs($0 - reading.offset) } ?? 10_000
        }
        try automaticScrollWheel(scroll, window: window, pixels: 1, phase: 1)
        try await waitForAutomaticHistoryLayout(controls, root: root)
        try automaticScrollWheel(scroll, window: window, pixels: 0, phase: 4)
        #expect(committed.stop() < 2, "A page insertion must not display even one displaced frame")
        let ids = automaticScrollRenderedMessageIDs(in: scroll)
        ranges.append(try #require(ids.min())...#require(ids.max()))
    }
    for (previous, current) in zip(ranges, ranges.dropFirst()) {
        #expect(current.lowerBound < previous.lowerBound)
    }
    let earlier = try #require(ranges.last)
    try #require(earlier.upperBound < 359, "The fixture must exceed the retained render budget")
    // Desktop rendering is bounded separately from the core's deep history.
    // Automatic later paging remains available if that budget excluded the tail.
    let controller = try #require(
        automaticScrollViews(in: root).compactMap { ($0 as? ConversationScrollBridge.MonitorView)?.controller }.first)
    // Keep the preceding page's hold active on both fast and slow workers.
    controller.holdReadingPosition()
    try automaticScrollWheelToEdge(scroll, window: window, earlier: false)
    try #require(
        scroll.contentView.bounds.maxY - scroll.contentInsets.bottom >= (scroll.documentView?.bounds.height ?? 0) - 2,
        "Downward input must reach the rendered edge even while a page anchor is held")
    let reading = try #require(automaticScrollReadingPosition(in: scroll))
    let committed = CommittedFrameSampler {
        automaticScrollTextPosition(reading.text, in: scroll).map { abs($0 - reading.offset) } ?? 10_000
    }
    try automaticScrollWheel(scroll, window: window, pixels: -1, phase: 1)
    try await waitForAutomaticHistoryLayout(controls, root: root)
    try automaticScrollWheel(scroll, window: window, pixels: 0, phase: 4)
    #expect(committed.stop() < 2, "Later paging must preserve the reader in every frame")
    #expect((automaticScrollRenderedMessageIDs(in: scroll).max() ?? 0) > earlier.upperBound)
}

/// Holds a history page open the way a slow network would, then publishes
/// it as the core does: earlier messages ahead of the live window.
@MainActor private final class AutomaticScrollLayoutCore {
    let core = ScriptedCoreClient()
    let snapshot: Dieter_V1_ConversationSnapshot
    private(set) var requestCount = 0
    private var earlier: [Dieter_V1_UiMessage] = []
    private var pending: CheckedContinuation<Void, Never>?

    init(_ snapshot: Dieter_V1_ConversationSnapshot) {
        self.snapshot = snapshot
        core.asyncHandler = { [unowned self] command in
            switch command.command {
            case .loadEarlierMessages:
                requestCount += 1
                publish(loading: true)
                await withCheckedContinuation { pending = $0 }
                let end = Int(snapshot.page.start) - earlier.count
                earlier = automaticScrollSnapshot(start: max(0, end - 60), end: end).conversation.messages + earlier
                publish()
                return .with { $0.pageLoaded = .with { $0.loaded = true } }
            case .returnToLatest:
                earlier = []
                publish()
            default: break
            }
            return .with { $0.done = ClientDone() }
        }
    }

    func publish(loading: Bool = false) {
        core.emitConversation(snapshot.detail.card.id) { slice in
            slice.card = snapshot.detail.card
            slice.conversation = snapshot.conversation
            slice.conversation.messages = []
            slice.messages = earlier + snapshot.conversation.messages
            slice.earlierCount = Int32(earlier.count)
            slice.page = snapshot.page
            slice.hasEarlier_p = Int(snapshot.page.start) - earlier.count > 0
            slice.loadingEarlier = loading
        }
    }

    func releasePage() {
        pending?.resume()
        pending = nil
    }
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
    try #require(
        scroll.convert(scroll.bounds, to: nil).contains(nativeEvent.locationInWindow),
        "Synthetic wheel location must land inside the hidden fixture's transcript: \(nativeEvent.locationInWindow)")
    if let content = window.contentView {
        for monitor in automaticScrollViews(in: content).compactMap({ $0 as? ConversationScrollBridge.MonitorView }
        ) {
            // Direct fixture dispatch bypasses NSApplication's local event
            // monitors, so deliver to the same production handler explicitly.
            monitor.handleScrollEvent(nativeEvent, in: window)
        }
    }
    // The fixture window is never ordered on screen. Sending the synthetic
    // event to AppKit can move its clip view later (or not at all), after the
    // observer has already reacted. Apply one native clip-view displacement
    // directly so headless runs cannot double-scroll or reverse the gesture.
    if pixels != 0 {
        var bounds = scroll.contentView.bounds
        bounds.origin.y -= CGFloat(pixels)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

@MainActor private func automaticScrollWheelToEdge(_ scroll: NSScrollView, window: NSWindow, earlier: Bool) throws {
    let distance = Int32(
        ceil((scroll.documentView?.bounds.height ?? 0) + scroll.contentInsets.top + scroll.contentInsets.bottom))
    try automaticScrollWheel(scroll, window: window, pixels: earlier ? distance : -distance, phase: 1)
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

/// Samples a displacement after Core Animation's commit on every run-loop
/// pass: what it sees is what reached the screen, including single frames.
@MainActor private final class CommittedFrameSampler {
    private var worst: CGFloat = 0
    private var observer: CFRunLoopObserver?

    init(_ displacement: @escaping @MainActor () -> CGFloat?) {
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) {
            [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let value = displacement() else { return }
                self.worst = max(self.worst, value)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func stop() -> CGFloat {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        return worst
    }
}

@MainActor private func waitForAutomaticHistoryLayout(_ controls: ConversationHistoryActions, root: NSView) async throws
{
    for _ in 0..<200 {
        await settleAutomaticScroll(root, milliseconds: 25)
        if !controls.isLoading() { return }
    }
    try #require(!controls.isLoading(), "History preparation and native layout must complete")
}

@MainActor private func settleAutomaticScroll(_ root: NSView, milliseconds: Int) async {
    root.layoutSubtreeIfNeeded()
    try? await DieterTaskSleep.milliseconds(milliseconds)
    root.layoutSubtreeIfNeeded()
}

@Test @MainActor func automaticTailWheelAndMomentumDoNotScheduleCorrections() async throws {
    let fixture = TailGestureFixture()
    defer { fixture.window.close() }
    try #require(await fixture.waitUntilInitiallyPositioned())
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
    try #require(await fixture.waitUntilInitiallyPositioned())
    let scroll = try fixture.scroll()
    let initialCorrections = fixture.tailCorrections
    // Queue content growth immediately before input, without allowing the tail
    // task to settle first. The event monitor must invalidate that pending work.
    fixture.appendText()
    try automaticScrollWheel(scroll, window: fixture.window, pixels: 1, phase: 1)
    await settleAutomaticScroll(fixture.root, milliseconds: 20)
    #expect(fixture.jumpVisible, "Even a small upward gesture relinquishes tail following")
    // Prepending an overlapping history window increases the absolute clip
    // offset even when the reader stays put. Compare visible message identity.
    var previousVisibleID = try #require(automaticScrollVisibleMessageID(in: scroll))
    for index in 0..<12 {
        fixture.appendText()
        try automaticScrollWheel(
            scroll, window: fixture.window, pixels: 12, phase: index < 6 ? 2 : 0,
            momentum: index < 6 ? 0 : (index == 6 ? 1 : 2))
        await settleAutomaticScroll(fixture.root, milliseconds: 20)
        let currentVisibleID = try #require(automaticScrollVisibleMessageID(in: scroll))
        #expect(currentVisibleID <= previousVisibleID, "Upward input must not show a newer message")
        previousVisibleID = currentVisibleID
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
    let store = DieterStore(liveEnvironment: false)
    let window: NSWindow
    var root: NSView { window.contentView! }
    var tailCorrections = 0
    var jumpVisible = false
    var detachTransitions = 0
    var initialPositionComplete = false

    init() {
        var snapshot = automaticScrollSnapshot(start: 0, end: 30)
        snapshot.page.hasMore_p = false
        store.state.chats = [snapshot.detail.card]
        store.chats = [snapshot.detail.card]
        store.selectedChatID = snapshot.detail.card.id
        store.conversation = snapshot
        store.selectedDetail = snapshot.detail
        store.conversationContext.model.resetHistory(to: snapshot)
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
                        initialPositionComplete = observation.initialPositionComplete
                        if !observation.followsLatest && !jumpVisible { detachTransitions += 1 }
                        jumpVisible = !observation.followsLatest
                    }
                )
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 100) }
                .environment(store).environment(store.conversationContext))
        root.sizingOptions = []
        window.contentView = root
    }

    func waitUntilInitiallyPositioned() async -> Bool {
        for _ in 0..<100 {
            await settleAutomaticScroll(root, milliseconds: 20)
            if initialPositionComplete { return true }
        }
        return false
    }

    func scroll() throws -> NSScrollView {
        try #require(
            automaticScrollViews(in: root).compactMap { $0 as? NSScrollView }.first {
                ($0.documentView?.bounds.height ?? 0)
                    > $0.contentView.bounds.height - $0.contentInsets.top - $0.contentInsets.bottom
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
    try #require(await fixture.waitUntilInitiallyPositioned())
    let scroll = try fixture.scroll()
    let committed = CommittedFrameSampler {
        abs(scroll.documentVisibleRect.maxY - scroll.contentInsets.bottom - (scroll.documentView?.bounds.maxY ?? 0))
    }
    for _ in 0..<6 {
        fixture.appendText()
        await settleAutomaticScroll(fixture.root, milliseconds: 30)
    }
    #expect(committed.stop() < 2, "No committed frame may show streamed growth below an unpinned viewport")
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
    try #require(await fixture.waitUntilInitiallyPositioned())
    let scroll = try fixture.scroll()
    let bottom = scroll.contentView.bounds.minY
    try automaticScrollWheel(scroll, window: fixture.window, pixels: 100, phase: 0)
    // AppKit applies phaseless wheel input asynchronously and, on a busy
    // machine, occasionally not at all; the subject here is what follows it.
    for attempt in 0..<30 {
        await settleAutomaticScroll(fixture.root, milliseconds: 80)
        if scroll.contentView.bounds.minY < bottom - 2 { break }
        if attempt % 6 == 5 { try automaticScrollWheel(scroll, window: fixture.window, pixels: 100, phase: 0) }
    }
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
