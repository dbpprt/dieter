import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

enum ConversationQueuePresentation {
    struct EditableDraft {
        let text: String
        let attachments: [Dieter_V1_MessagePart]
    }

    static func deliveredMessages(
        _ messages: [Dieter_V1_UiMessage],
        whileQueued queue: [Dieter_V1_QueuedMessage]
    ) -> [Dieter_V1_UiMessage] {
        let queuedIDs = Set(queue.lazy.map(\.id).filter { !$0.isEmpty })
        return messages.filter { !queuedIDs.contains($0.id) }
    }

    static func canSteer(
        messageID: String,
        queue: [Dieter_V1_QueuedMessage],
        agentIsWorking: Bool
    ) -> Bool {
        agentIsWorking && !messageID.isEmpty && queue.first?.id == messageID
    }

    static func editableDraft(for message: Dieter_V1_QueuedMessage) -> EditableDraft {
        let textParts = message.parts.filter { $0.type == "text" }.map(\.text)
        let text = textParts.isEmpty ? message.text : textParts.joined()
        return EditableDraft(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: message.parts.filter { $0.type != "text" }
        )
    }
}
struct ConversationAgentWorkingIndicator: View {
    let label: String
    let startedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    var body: some View {
        HStack(spacing: 8) {
            DieterActivityIndicator(size: 12).accessibilityHidden(true)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(DieterTheme.subtle)
                .overlay {
                    if !reduceMotion {
                        GeometryReader { geometry in
                            LinearGradient(
                                colors: [.clear, DieterTheme.text, .clear], startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: geometry.size.width)
                            .offset(x: shimmer ? geometry.size.width : -geometry.size.width)
                        }
                        .mask(Text(label).font(.caption.weight(.medium)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
            if let startedAt {
                Text(startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DieterTheme.subtle)
                    .accessibilityLabel("Elapsed time")
                    .fixedSize()
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(DieterTheme.surface.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(DieterTheme.primary.opacity(0.18)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.agent-working")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { shimmer = true }
        }
    }
}

enum ConversationScrollBehavior {
    static let bottomID = "conversation.bottom"
    private static let latestTolerance: CGFloat = 2

    static func isAtLatest(
        visibleMaxY: CGFloat,
        contentHeight: CGFloat,
        bottomInset: CGFloat = 0,
        renderedThroughLatest: Bool = true
    ) -> Bool {
        // The scroll view extends behind the floating composer. Only the
        // unobscured area counts, including after the composer grows taller.
        renderedThroughLatest && visibleMaxY - bottomInset >= contentHeight - latestTolerance
    }

    static func followsLatest(_ viewportMode: ConversationViewportMode) -> Bool {
        switch viewportMode {
        case .awaitingInitial, .followingLatest:
            true
        case .detached:
            false
        }
    }

    static func showsJumpToLatest(viewportMode: ConversationViewportMode) -> Bool {
        viewportMode == .detached
    }

    static func initialPositionComplete(_ viewportMode: ConversationViewportMode) -> Bool {
        if case .awaitingInitial = viewportMode { return false }
        return true
    }

    static func afterUserScroll(isAtLatest: Bool) -> ConversationViewportMode {
        isAtLatest ? .followingLatest : .detached
    }
}

enum ConversationViewportMode: Equatable {
    case awaitingInitial(conversationID: String)
    case followingLatest
    case detached
}

enum ConversationTimelinePresentation {
    static func isReady(
        messageCount: Int,
        conversationID: String,
        projectionConversationID: String,
        viewportMode: ConversationViewportMode
    ) -> Bool {
        guard messageCount > 0 else { return true }
        guard projectionConversationID == conversationID else { return false }
        if case .awaitingInitial = viewportMode { return false }
        return true
    }
}

struct ConversationViewportObservation: Equatable {
    let conversationID: String
    let isAtLatest: Bool
    let followsLatest: Bool
    let initialPositionComplete: Bool
}

struct EmptyConversationView: View {
    let standalone: Bool
    let prompt: String
    let attachments: [Dieter_V1_MessagePart]
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left").font(.system(size: 24)).foregroundStyle(DieterTheme.shell)
            Text("Ready when you are").font(.headline)
            Text(
                standalone
                    ? "Start a focused conversation in this project."
                    : "Send this card's brief to start its local harness session."
            )
            .font(.caption).foregroundStyle(DieterTheme.tertiary).multilineTextAlignment(.center)
            if !prompt.isEmpty || !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    if !prompt.isEmpty { Text(prompt).font(.callout) }
                    if !attachments.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { _, part in
                                AttachmentPreviewTile(part: part)
                            }
                        }
                    }
                }
                .padding(12).frame(maxWidth: 520, alignment: .leading)
                .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 55)
    }
}

/// Single owner of the transcript's native scroll position.
///
/// SwiftUI publishes scroll geometry only after a frame has been laid out, so
/// corrections made from SwiftUI state always land one frame late and show up
/// as flicker or as a viewport fighting the user's wheel. This controller
/// observes the underlying `NSScrollView` directly and applies exactly one
/// rule inside the layout pass that changed the content, before it is drawn:
///
/// - following: the viewport stays pinned to the newest content;
/// - reading position pending: the captured row stays at the same pixel;
/// - otherwise AppKit's default applies and the top offset is left alone.
///
/// Following ends only through user input and resumes only when the user
/// scrolls back down to the end (or asks to jump there).
@MainActor
final class ConversationScrollController: NSObject {
    struct Anchor: Equatable {
        let messageIDs: [String]
        /// Distance from the viewport's top edge to the row's top and bottom.
        let top: CGFloat
        let bottom: CGFloat
    }

    struct ReadingPosition: Equatable {
        /// Visible rows, nearest the top of the viewport first.
        let anchors: [Anchor]
    }

    struct EdgeProximity: Equatable {
        let movedEarlier: Bool
        let nearStart: Bool
        let nearEnd: Bool
    }

    private struct Registration {
        weak var view: NSView?
        var messageIDs: [String]
    }

    private struct Layout: Equatable {
        var documentHeight: CGFloat = 0
        var viewportHeight: CGFloat = 0
        var topInset: CGFloat = 0
        var bottomInset: CGFloat = 0
    }

    private static let edgeTolerance: CGFloat = 2

    private var registrations: [ObjectIdentifier: Registration] = [:]
    private weak var attachedScrollView: NSScrollView?
    private weak var observedDocument: NSView?
    private var lastLayout = Layout()
    private var lastOffset: CGFloat = 0
    private var isAdjusting = false
    private var verificationScheduled = false
    private var pendingReadingPosition: ReadingPosition?
    private var holdGeneration = 0
    private var holdSawLayout = false
    nonisolated(unsafe) private var verificationObserver: CFRunLoopObserver?

    /// Whether the viewport tracks the newest content.
    private(set) var isFollowing = true
    /// The rendered rows end at the conversation's newest message, so reaching
    /// the rendered end means reaching the live tail.
    var rendersLatest = true
    private(set) var contentCanScroll = true

    // Delivered on the next main-queue turn: they mutate SwiftUI state, which
    // must not happen inside the AppKit layout pass that produced them.
    var onFollowingChange: (Bool) -> Void = { _ in }
    var onUserScroll: (EdgeProximity) -> Void = { _ in }
    var onScrollableChange: (Bool) -> Void = { _ in }
    /// Test instrumentation: a programmatic pin actually moved the viewport.
    var onTailCorrection: (() -> Void)?

    var scrollView: NSScrollView? { attachedScrollView }
    private var resolvedScrollView: NSScrollView? {
        attachedScrollView ?? registrations.values.lazy.compactMap { $0.view?.enclosingScrollView }.first
    }

    // MARK: Row registration

    func register(_ view: NSView, messageIDs: [String]) {
        registrations[ObjectIdentifier(view)] = Registration(view: view, messageIDs: messageIDs)
        attachIfNeeded(from: view)
    }

    func unregister(_ view: NSView) {
        registrations.removeValue(forKey: ObjectIdentifier(view))
    }

    func attachIfNeeded(from view: NSView) {
        guard let scroll = view.enclosingScrollView else { return }
        guard scroll !== attachedScrollView || scroll.documentView !== observedDocument else { return }
        let center = NotificationCenter.default
        center.removeObserver(self)
        attachedScrollView = scroll
        observedDocument = scroll.documentView
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        center.addObserver(
            self, selector: #selector(clipBoundsDidChange), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        center.addObserver(
            self, selector: #selector(layoutDidChange), name: NSView.frameDidChangeNotification,
            object: scroll.contentView)
        installVerificationObserver()
        if let document = scroll.documentView {
            document.postsFrameChangedNotifications = true
            center.addObserver(
                self, selector: #selector(layoutDidChange), name: NSView.frameDidChangeNotification,
                object: document)
        }
        applyLayoutPolicy()
    }

    // MARK: Commands

    /// Forgets the previous conversation and tracks the next one's tail.
    func reset() {
        pendingReadingPosition = nil
        isFollowing = true
        rendersLatest = true
        applyLayoutPolicy()
    }

    /// Pins the viewport to the newest content and keeps it there.
    func follow() {
        pendingReadingPosition = nil
        setFollowing(true)
        applyLayoutPolicy()
    }

    /// The user asked for older content; stop tracking the tail right away so
    /// content streaming in during the same frame cannot undo their input.
    func detach() {
        setFollowing(false)
    }

    /// Call immediately before replacing rows around the reader. The row the
    /// user is looking at keeps its pixel position through the replacement.
    ///
    /// The hold outlives the replacement's layout passes and then lapses by
    /// itself, so an abandoned replacement can never trap the viewport. While
    /// it lasts, user scrolling simply moves the held position along.
    func holdReadingPosition() {
        guard !isFollowing, let position = capture() else { return }
        pendingReadingPosition = position
        holdSawLayout = false
        expireHold(after: .seconds(2))
    }

    private func expireHold(after delay: DispatchTimeInterval) {
        holdGeneration &+= 1
        let generation = holdGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, holdGeneration == generation else { return }
            pendingReadingPosition = nil
        }
    }

    func isAtEdge(earlier: Bool) -> Bool {
        guard let scroll = attachedScrollView, let document = scroll.documentView else { return false }
        if earlier { return scroll.contentView.bounds.minY <= -scroll.contentInsets.top + Self.edgeTolerance }
        return scroll.contentView.bounds.maxY - scroll.contentInsets.bottom
            >= document.bounds.height - Self.edgeTolerance
    }

    // MARK: Reading position

    func capture() -> ReadingPosition? {
        registrations = registrations.filter { $0.value.view != nil }
        guard let scroll = resolvedScrollView,
            let document = scroll.documentView
        else { return nil }
        let viewport = scroll.contentView.bounds
        // The scroll view extends behind the floating composer; rows entirely
        // underneath it are not what the user is reading.
        let readableMaxY = viewport.maxY - scroll.contentInsets.bottom
        let anchors = registrations.values.compactMap { registration -> Anchor? in
            guard let view = registration.view, view.enclosingScrollView === scroll,
                registration.messageIDs.contains(where: { !$0.isEmpty })
            else { return nil }
            let frame = view.convert(view.bounds, to: document)
            guard frame.maxY > viewport.minY, frame.minY < readableMaxY else { return nil }
            return Anchor(
                messageIDs: registration.messageIDs, top: frame.minY - viewport.minY,
                bottom: frame.maxY - viewport.minY)
        }
        guard !anchors.isEmpty else { return nil }
        // Rows crossing the top edge first (innermost first), then downwards.
        return ReadingPosition(
            anchors: anchors.sorted {
                let lhs = $0.top <= 0, rhs = $1.top <= 0
                if lhs != rhs { return lhs }
                return lhs ? $0.top > $1.top : $0.top < $1.top
            })
    }

    @discardableResult
    func restore(_ position: ReadingPosition) -> Bool {
        guard let scroll = resolvedScrollView,
            let document = scroll.documentView
        else { return false }
        let live = registrations.values.filter { $0.view?.enclosingScrollView === scroll }
        func frame(_ registration: Registration) -> CGRect? {
            registration.view.map { $0.convert($0.bounds, to: document) }
        }
        // Rows at the edge of a replaced window can regroup with their new
        // neighbours and change height. Prefer a row that is unchanged, then a
        // row whose matching edge is still the same message.
        var target: CGFloat?
        for anchor in position.anchors where target == nil {
            if let match = live.first(where: { $0.messageIDs == anchor.messageIDs }), let frame = frame(match) {
                target = frame.minY - anchor.top
            }
        }
        for anchor in position.anchors where target == nil {
            if let match = live.first(where: { $0.messageIDs.first == anchor.messageIDs.first }),
                let frame = frame(match)
            {
                target = frame.minY - anchor.top
            } else if let match = live.first(where: { $0.messageIDs.last == anchor.messageIDs.last }),
                let frame = frame(match)
            {
                target = frame.maxY - anchor.bottom
            }
        }
        guard let target else { return false }
        move(scroll, toOffset: target)
        return true
    }

    // MARK: Native observation

    func rowDidMove() {
        guard pendingReadingPosition != nil else { return }
        applyLayoutPolicy()
    }

    @objc private func layoutDidChange(_ notification: Notification) {
        applyLayoutPolicy()
    }

    deinit {
        if let verificationObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), verificationObserver, .commonModes) }
    }

    @objc private func clipBoundsDidChange(_ notification: Notification) {
        guard !isAdjusting, let scroll = attachedScrollView else { return }
        let layout = currentLayout(scroll)
        guard layout == lastLayout else {
            // Inset or size changes move the clip origin too; that is layout,
            // not the user.
            applyLayoutPolicy()
            return
        }
        let offset = scroll.contentView.bounds.minY
        let delta = offset - lastOffset
        lastOffset = offset
        guard abs(delta) > 0.01 else { return }
        if pendingReadingPosition != nil { pendingReadingPosition = capture() }
        let atEnd = isAtEdge(earlier: false)
        if delta < 0, !atEnd {
            setFollowing(false)
        } else if delta > 0, atEnd, rendersLatest {
            setFollowing(true)
        }
        let reach = max(160, layout.viewportHeight)
        let proximity = EdgeProximity(
            movedEarlier: delta < 0,
            nearStart: offset <= -layout.topInset + reach,
            nearEnd: offset + layout.viewportHeight - layout.bottomInset >= layout.documentHeight - reach)
        if proximity.nearStart || proximity.nearEnd {
            DispatchQueue.main.async { [weak self] in self?.onUserScroll(proximity) }
        }
    }

    private func currentLayout(_ scroll: NSScrollView) -> Layout {
        Layout(
            documentHeight: scroll.documentView?.frame.height ?? 0,
            viewportHeight: scroll.contentView.bounds.height,
            topInset: scroll.contentInsets.top,
            bottomInset: scroll.contentInsets.bottom)
    }

    /// Runs inside the layout pass that changed the content or the viewport.
    private func applyLayoutPolicy() {
        guard !isAdjusting, let scroll = attachedScrollView else { return }
        if let pendingReadingPosition {
            restore(pendingReadingPosition)
        } else if isFollowing {
            pinToEnd(scroll)
        }
        let layout = currentLayout(scroll)
        lastLayout = layout
        lastOffset = scroll.contentView.bounds.minY
        let canScroll =
            layout.documentHeight > layout.viewportHeight - layout.topInset - layout.bottomInset + Self.edgeTolerance
        if canScroll != contentCanScroll {
            contentCanScroll = canScroll
            DispatchQueue.main.async { [weak self] in self?.onScrollableChange(canScroll) }
        }
        scheduleVerification()
    }

    /// SwiftUI resizes the document before it moves the rows inside it, so a
    /// rule applied at the frame change can see stale row frames. Re-apply it
    /// once AppKit's layout has settled, immediately before Core Animation
    /// commits the frame. The observer must already exist when layout runs:
    /// one added during a run-loop pass does not fire in that pass.
    private func installVerificationObserver() {
        guard verificationObserver == nil else { return }
        // Core Animation commits at order 2_000_000; AppKit lays out before it.
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_999
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.verifyLayoutPolicy() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        verificationObserver = observer
    }

    private func scheduleVerification() {
        verificationScheduled = true
    }

    private func verifyLayoutPolicy() {
        guard verificationScheduled else { return }
        verificationScheduled = false
        guard let scroll = attachedScrollView, !isAdjusting else { return }
        if let pendingReadingPosition {
            restore(pendingReadingPosition)
            // The replacement has been laid out. Text rows may still settle
            // over the next passes; after that the hold has done its job.
            if !holdSawLayout {
                holdSawLayout = true
                expireHold(after: .milliseconds(300))
            }
        } else if isFollowing {
            pinToEnd(scroll)
        }
        lastLayout = currentLayout(scroll)
        lastOffset = scroll.contentView.bounds.minY
    }

    private func pinToEnd(_ scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let target = document.frame.height - clip.bounds.height + scroll.contentInsets.bottom
        // Past the end is the native elastic bounce (or AppKit about to clamp
        // a shrunken document); both settle by themselves.
        guard clip.bounds.minY < target else { return }
        if move(scroll, toOffset: target) { onTailCorrection?() }
    }

    @discardableResult
    private func move(_ scroll: NSScrollView, toOffset offset: CGFloat) -> Bool {
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y = offset
        let origin = clip.constrainBoundsRect(bounds).origin
        guard abs(origin.y - clip.bounds.minY) > 0.5 else { return false }
        isAdjusting = true
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        isAdjusting = false
        lastOffset = clip.bounds.minY
        return true
    }

    private func setFollowing(_ following: Bool) {
        guard following != isFollowing else { return }
        isFollowing = following
        if following { pendingReadingPosition = nil }
        DispatchQueue.main.async { [weak self] in
            guard let self, isFollowing == following else { return }
            onFollowingChange(following)
        }
    }
}

struct ConversationScrollAnchorProbe: NSViewRepresentable {
    let controller: ConversationScrollController
    let messageIDs: [String]

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.controller = controller
        controller.register(view, messageIDs: messageIDs)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        if view.controller !== controller {
            view.controller?.unregister(view)
            view.controller = controller
        }
        controller.register(view, messageIDs: messageIDs)
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.controller?.unregister(view)
    }

    final class ProbeView: NSView {
        weak var controller: ConversationScrollController?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { controller?.attachIfNeeded(from: self) }
            observeAncestors()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            observeAncestors()
        }

        // SwiftUI resizes the document first and moves its rows afterwards,
        // inside one layout pass, by moving the containers that host each
        // row's platform view. Each move is the moment a held reading
        // position can be re-established against current row frames.
        private func observeAncestors() {
            let center = NotificationCenter.default
            center.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
            guard window != nil, let document = enclosingScrollView?.documentView else { return }
            var ancestor = superview
            while let view = ancestor, view !== document {
                view.postsFrameChangedNotifications = true
                center.addObserver(
                    self, selector: #selector(ancestorFrameDidChange), name: NSView.frameDidChangeNotification,
                    object: view)
                ancestor = view.superview
            }
        }

        @objc private func ancestorFrameDidChange(_ notification: Notification) {
            controller?.rowDidMove()
        }
    }
}

/// Connects the native controller to the SwiftUI timeline and observes wheel
/// intent. Wheel intent still exists when the clip view is clamped at an edge
/// and there is no movement to observe. The original event is never
/// intercepted, so selection and native scrolling are unaffected.
struct ConversationScrollBridge: NSViewRepresentable {
    let controller: ConversationScrollController
    let rendersLatest: Bool
    let onFollowingChange: (Bool) -> Void
    let onUserScroll: (ConversationScrollController.EdgeProximity) -> Void
    let onScrollableChange: (Bool) -> Void
    let onScrollIntent: (CGFloat) -> Void
    var onTailCorrection: (() -> Void)?

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.controller = controller
        view.onScrollIntent = onScrollIntent
        controller.rendersLatest = rendersLatest
        controller.onFollowingChange = onFollowingChange
        controller.onUserScroll = onUserScroll
        controller.onScrollableChange = onScrollableChange
        controller.onTailCorrection = onTailCorrection
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        weak var controller: ConversationScrollController?
        var onScrollIntent: (CGFloat) -> Void = { _ in }
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEvent(event, in: event.window)
                return event
            }
        }

        func stopMonitoring() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }

        func handleScrollEvent(_ event: NSEvent, in eventWindow: NSWindow?) {
            guard event.type == .scrollWheel, event.scrollingDeltaY != 0,
                abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
                let window, eventWindow === window,
                let scroll = controller?.scrollView,
                scroll.convert(scroll.bounds, to: nil).contains(event.locationInWindow)
            else { return }
            // The floating composer and nested code scrollers own their wheel
            // events even though their frames overlap the transcript viewport.
            if let content = window.contentView,
                let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            {
                guard ((hit as? NSScrollView) ?? hit.enclosingScrollView) === scroll else { return }
            }
            onScrollIntent(event.scrollingDeltaY)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
