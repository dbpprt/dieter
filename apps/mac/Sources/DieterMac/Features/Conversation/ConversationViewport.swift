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
        HStack(spacing: 9) {
            ConversationDieterActivityGlyph(size: 16)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .overlay {
                    if !reduceMotion {
                        GeometryReader { geometry in
                            LinearGradient(
                                colors: [.clear, .primary.opacity(0.8), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
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
            Spacer(minLength: 8)
            if let startedAt {
                Text(startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Elapsed turn time")
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .dieterGlass(.regular.interactive(), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.agent-working")
        .smokeTarget("conversation.agent-working")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { shimmer = true }
        }
    }
}

/// The single live turn at the transcript tail can afford the richer animated
/// Dieter mark used by iOS. List and status-row activity indicators stay static
/// so scrolling performance is unchanged.
private struct ConversationDieterActivityGlyph: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = Angle.zero
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(DieterTheme.primary.opacity(0.16))
                .frame(width: size * 1.18, height: size * 1.18)
                .blur(radius: size * 0.17)
                .scaleEffect(breathing ? 1.08 : 0.92)
            Circle()
                .stroke(DieterTheme.primary.opacity(0.14), lineWidth: max(1, size * 0.025))
                .frame(width: size, height: size)
            Circle()
                .trim(from: 0.08, to: 0.73)
                .stroke(
                    AngularGradient(
                        colors: [.clear, DieterTheme.primary.opacity(0.35), DieterTheme.primary, .clear],
                        center: .center),
                    style: StrokeStyle(lineWidth: max(2, size * 0.055), lineCap: .round)
                )
                .frame(width: size, height: size)
                .rotationEffect(rotation)
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: size * 0.7, height: size * 0.7)
                .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 0.75))
            ConversationDieterMark()
                .frame(width: size * 0.52, height: size * 0.52)
                .scaleEffect(breathing ? 1.04 : 0.94)
                .rotationEffect(breathing ? .degrees(2) : .degrees(-2))
                .shadow(color: DieterTheme.primary.opacity(0.22), radius: size * 0.06, y: size * 0.02)
        }
        .frame(width: size * 1.25, height: size * 1.25)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.7).repeatForever(autoreverses: false)) {
                rotation = .degrees(360)
            }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ConversationDieterMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 1_024
            context.translateBy(
                x: (size.width - 1_024 * scale) / 2,
                y: (size.height - 1_024 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            context.fill(
                shell,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.55, green: 0.85, blue: 0.91),
                        Color(red: 0.24, green: 0.43, blue: 0.52),
                        Color(red: 0.20, green: 0.35, blue: 0.43),
                    ]),
                    startPoint: CGPoint(x: 190, y: 160),
                    endPoint: CGPoint(x: 862, y: 912)))
            context.fill(operatorBody, with: .color(Color(red: 0.05, green: 0.11, blue: 0.14)))
            context.fill(
                panes,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.84, green: 0.95, blue: 0.96),
                        Color(red: 0.55, green: 0.85, blue: 0.91),
                        Color(red: 0.38, green: 0.71, blue: 0.80),
                    ]),
                    startPoint: CGPoint(x: 250, y: 220),
                    endPoint: CGPoint(x: 730, y: 850)))
            context.fill(eyes, with: .color(Color(red: 0.74, green: 0.92, blue: 0.95)))
        }
        .accessibilityHidden(true)
    }

    private var shell: Path {
        var path = Path()
        path.move(to: CGPoint(x: 742, y: 104))
        path.addLine(to: CGPoint(x: 862, y: 104))
        path.addLine(to: CGPoint(x: 862, y: 686))
        path.addCurve(
            to: CGPoint(x: 630, y: 918),
            control1: CGPoint(x: 862, y: 814),
            control2: CGPoint(x: 758, y: 918))
        path.addLine(to: CGPoint(x: 394, y: 918))
        path.addCurve(
            to: CGPoint(x: 162, y: 686),
            control1: CGPoint(x: 266, y: 918),
            control2: CGPoint(x: 162, y: 814))
        path.addLine(to: CGPoint(x: 162, y: 493))
        path.addCurve(
            to: CGPoint(x: 512, y: 143),
            control1: CGPoint(x: 162, y: 300),
            control2: CGPoint(x: 319, y: 143))
        path.addCurve(
            to: CGPoint(x: 742, y: 226),
            control1: CGPoint(x: 599, y: 143),
            control2: CGPoint(x: 679, y: 175))
        path.closeSubpath()
        return path
    }

    private var operatorBody: Path {
        var path = Path()
        path.move(to: CGPoint(x: 512, y: 342))
        path.addCurve(
            to: CGPoint(x: 288, y: 534),
            control1: CGPoint(x: 374, y: 342),
            control2: CGPoint(x: 288, y: 425))
        path.addCurve(
            to: CGPoint(x: 394, y: 688),
            control1: CGPoint(x: 288, y: 603),
            control2: CGPoint(x: 326, y: 650))
        path.addLine(to: CGPoint(x: 394, y: 786))
        path.addCurve(
            to: CGPoint(x: 495, y: 887),
            control1: CGPoint(x: 394, y: 842),
            control2: CGPoint(x: 439, y: 887))
        path.addLine(to: CGPoint(x: 529, y: 887))
        path.addCurve(
            to: CGPoint(x: 630, y: 786),
            control1: CGPoint(x: 585, y: 887),
            control2: CGPoint(x: 630, y: 842))
        path.addLine(to: CGPoint(x: 630, y: 688))
        path.addCurve(
            to: CGPoint(x: 736, y: 534),
            control1: CGPoint(x: 698, y: 650),
            control2: CGPoint(x: 736, y: 603))
        path.addCurve(
            to: CGPoint(x: 512, y: 342),
            control1: CGPoint(x: 736, y: 425),
            control2: CGPoint(x: 650, y: 342))
        path.closeSubpath()
        return path
    }

    private var panes: Path {
        var path = Path(
            roundedRect: CGRect(x: 412, y: 224, width: 200, height: 142),
            cornerSize: CGSize(width: 36, height: 36))
        path.addPath(sidePane(mirrored: false))
        path.addPath(sidePane(mirrored: true))
        return path
    }

    private func sidePane(mirrored: Bool) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 218, y: 668))
        path.addCurve(
            to: CGPoint(x: 277, y: 622),
            control1: CGPoint(x: 218, y: 636),
            control2: CGPoint(x: 246, y: 614))
        path.addLine(to: CGPoint(x: 370, y: 647))
        path.addCurve(
            to: CGPoint(x: 418, y: 710),
            control1: CGPoint(x: 398, y: 655),
            control2: CGPoint(x: 418, y: 680))
        path.addLine(to: CGPoint(x: 418, y: 817))
        path.addCurve(
            to: CGPoint(x: 361, y: 864),
            control1: CGPoint(x: 418, y: 847),
            control2: CGPoint(x: 390, y: 870))
        path.addLine(to: CGPoint(x: 275, y: 847))
        path.addCurve(
            to: CGPoint(x: 218, y: 778),
            control1: CGPoint(x: 242, y: 840),
            control2: CGPoint(x: 218, y: 811))
        path.closeSubpath()
        guard mirrored else { return path }
        return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1_024, ty: 0))
    }

    private var eyes: Path {
        var path = Path(
            roundedRect: CGRect(x: 376, y: 516, width: 88, height: 36),
            cornerSize: CGSize(width: 18, height: 18))
        path.addRoundedRect(
            in: CGRect(x: 560, y: 516, width: 88, height: 36),
            cornerSize: CGSize(width: 18, height: 18))
        return path
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
        var documentWidth: CGFloat = 0
        var documentHeight: CGFloat = 0
        var viewportWidth: CGFloat = 0
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
    private var initialPositioning = false
    private var verificationScheduled = false
    private var wheelIntent: CGFloat = 0
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
    func hasLaidOutMessage(_ id: String) -> Bool {
        registrations.values.contains { registration in
            guard registration.messageIDs.contains(id), let view = registration.view else { return false }
            return view.window != nil && view.bounds.width > 0 && view.bounds.height > 0
        }
    }

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
        wheelIntent = 0
        initialPositioning = false
        isFollowing = true
        rendersLatest = true
        applyLayoutPolicy()
    }

    func beginInitialPositioning() { initialPositioning = true }

    func finishInitialPositioning() {
        applyLayoutPolicy()
        initialPositioning = false
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
        initialPositioning = false
        setFollowing(false)
    }

    func recordWheelIntent(_ delta: CGFloat) { wheelIntent = delta }
    func endWheelIntent() { wheelIntent = 0 }

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
        // Initial row placement and viewport filling can move the native clip
        // before the transcript is revealed. Those movements are not input.
        // A real wheel gesture calls detach() first and ends this protection.
        guard !initialPositioning else { applyLayoutPolicy(); return }
        let layout = currentLayout(scroll)
        let offset = scroll.contentView.bounds.minY
        guard layout == lastLayout, !(verificationScheduled && isFollowing) else {
            // Inset or size changes move the clip origin too; that is layout,
            // not the user. AppKit may clamp the origin after the frame
            // notification but before the pending layout verification.
            applyLayoutPolicy()
            return
        }
        let delta = offset - lastOffset
        lastOffset = offset
        guard abs(delta) > 0.01 else { return }
        // Row replacement and native anchoring can translate the clip in the
        // opposite direction to the wheel. That is layout, not a reversal by
        // the reader; don't replace the held anchor or rejoin the live tail.
        if wheelIntent * delta > 0 {
            applyLayoutPolicy()
            return
        }
        if pendingReadingPosition != nil { pendingReadingPosition = capture() }
        let atEnd = isAtEdge(earlier: false)
        if delta < 0, !atEnd {
            setFollowing(false)
        } else if delta > 0, atEnd, rendersLatest {
            setFollowing(true)
        }
        // A small initial window needs some actual scrolling before it grows.
        // A full viewport of preload reach can cover that entire window and
        // turn the first one-pixel gesture into an immediate page replacement.
        let scrollableHeight = max(
            0, layout.documentHeight - layout.viewportHeight + layout.topInset + layout.bottomInset)
        let reach = min(max(160, layout.viewportHeight), scrollableHeight / 2)
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
            documentWidth: scroll.documentView?.frame.width ?? 0,
            documentHeight: scroll.documentView?.frame.height ?? 0,
            viewportWidth: scroll.contentView.bounds.width,
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
        guard let scroll = attachedScrollView, !isAdjusting else { return }
        // A floating composer can change contentInsets without changing the
        // document or clip frame. Those changes produce no layout notification.
        guard verificationScheduled || currentLayout(scroll) != lastLayout else { return }
        verificationScheduled = false
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
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) {
                [weak self] event in
                if let self, event.window === window,
                    let scroll = controller?.scrollView,
                    event.type == .keyDown
                        || event.type == .leftMouseDown
                            && scroll.convert(scroll.bounds, to: nil).contains(event.locationInWindow)
                {
                    // Scrollbar and keyboard input must work independently of
                    // the direction of the previous wheel gesture.
                    controller?.endWheelIntent()
                } else {
                    self?.handleScrollEvent(event, in: event.window)
                }
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
            controller?.recordWheelIntent(event.scrollingDeltaY)
            onScrollIntent(event.scrollingDeltaY)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
