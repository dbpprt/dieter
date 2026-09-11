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

    static func afterUserScroll(isAtLatest: Bool) -> ConversationViewportMode {
        isAtLatest ? .followingLatest : .detached
    }

    static func isUserDriven(_ phase: ScrollPhase) -> Bool {
        phase.isScrolling && phase != .animating
    }

    static func anchorItem(containing messageID: String?, in items: [ConversationTimelineItem]) -> String? {
        guard let messageID, !messageID.isEmpty else { return nil }
        return items.first { item in item.messages.contains { $0.id == messageID } }?.id
    }
}

enum ConversationViewportMode: Equatable {
    case awaitingInitial(conversationID: String)
    case followingLatest
    case detached
}

struct ConversationViewportObservation: Equatable {
    let conversationID: String
    let isAtLatest: Bool
    let followsLatest: Bool
    let initialPositionComplete: Bool
}

struct ConversationTailScrollKey: Equatable {
    let conversationID: String
    let request: Int
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

/// Records an actual visible row position, independent of page size or grouped
/// activity IDs. A page replacement restores that same point in the viewport.
@MainActor
final class ConversationScrollAnchorController {
    struct Anchor: Equatable {
        let messageID: String
        let offset: CGFloat
    }

    private struct Registration {
        weak var view: NSView?
        var messageIDs: [String]
        var priority: Int
    }
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private(set) var lastRestoredOffset: CGFloat?

    func register(_ view: NSView, messageIDs: [String], priority: Int = 0) {
        registrations[ObjectIdentifier(view)] = Registration(view: view, messageIDs: messageIDs, priority: priority)
    }

    func unregister(_ view: NSView) {
        registrations.removeValue(forKey: ObjectIdentifier(view))
    }

    var scrollView: NSScrollView? {
        registrations.values.compactMap { $0.view?.enclosingScrollView }.first
    }

    func isAtEdge(earlier: Bool) -> Bool {
        guard let scroll = scrollView, let document = scroll.documentView else { return false }
        if earlier { return scroll.contentView.bounds.minY <= -scroll.contentInsets.top + 2 }
        return scroll.contentView.bounds.maxY - scroll.contentInsets.bottom >= document.bounds.height - 2
    }

    func capture(preferBottom: Bool = false) -> Anchor? {
        registrations = registrations.filter { $0.value.view != nil }
        let visible = registrations.values.compactMap { registration -> (String, CGFloat, Int)? in
            guard let view = registration.view, let scroll = view.enclosingScrollView,
                let document = scroll.documentView,
                let messageID = preferBottom ? registration.messageIDs.last : registration.messageIDs.first,
                !messageID.isEmpty
            else { return nil }
            let frame = view.convert(view.bounds, to: document)
            let viewport = scroll.contentView.bounds
            guard frame.maxY > viewport.minY,
                frame.minY < viewport.maxY - scroll.contentInsets.bottom
            else { return nil }
            return (messageID, frame.minY - viewport.minY, registration.priority)
        }
        if preferBottom,
            let last = visible.max(by: {
                $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1
            })
        {
            return Anchor(messageID: last.0, offset: last.1)
        }
        let crossingTop = visible.filter { $0.1 <= 0 }
        let first =
            crossingTop.max {
                $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1
            } ?? visible.min { $0.1 < $1.1 }
        guard let first else { return nil }
        return Anchor(messageID: first.0, offset: first.1)
    }

    @discardableResult
    func restore(_ anchor: Anchor) -> Bool {
        guard
            let registration = registrations.values.filter({
                $0.view?.enclosingScrollView != nil && $0.messageIDs.contains(anchor.messageID)
            }).max(by: {
                $0.priority == $1.priority
                    ? ($0.view?.bounds.height ?? .infinity) > ($1.view?.bounds.height ?? .infinity)
                    : $0.priority < $1.priority
            }), let view = registration.view, let scroll = view.enclosingScrollView,
            let document = scroll.documentView
        else { return false }
        scroll.superview?.layoutSubtreeIfNeeded()
        let frame = view.convert(view.bounds, to: document)
        var bounds = scroll.contentView.bounds
        bounds.origin.y = frame.minY - anchor.offset
        let constrained = scroll.contentView.constrainBoundsRect(bounds)
        lastRestoredOffset = constrained.origin.y
        scroll.contentView.scroll(to: constrained.origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }
}

struct ConversationScrollAnchorProbe: NSViewRepresentable {
    let controller: ConversationScrollAnchorController
    let messageIDs: [String]
    var priority = 0

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.controller = controller
        controller.register(view, messageIDs: messageIDs, priority: priority)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        if view.controller !== controller {
            view.controller?.unregister(view)
            view.controller = controller
        }
        controller.register(view, messageIDs: messageIDs, priority: priority)
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.controller?.unregister(view)
    }

    final class ProbeView: NSView {
        weak var controller: ConversationScrollAnchorController?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct ConversationScrollSample: Equatable {
    let offset: CGFloat
    let nearStart: Bool
    let nearEnd: Bool
    let atEnd: Bool
    let canScroll: Bool

    init(_ geometry: ScrollGeometry) {
        offset = geometry.visibleRect.minY
        canScroll = geometry.contentSize.height > geometry.visibleRect.height - geometry.contentInsets.bottom + 2
        nearStart = offset <= 160
        nearEnd = geometry.visibleRect.maxY - geometry.contentInsets.bottom >= geometry.contentSize.height - 160
        atEnd = ConversationScrollBehavior.isAtLatest(
            visibleMaxY: geometry.visibleRect.maxY,
            contentHeight: geometry.contentSize.height,
            bottomInset: geometry.contentInsets.bottom
        )
    }
}

/// Native wheel intent still exists when the clip view is clamped at an edge
/// and SwiftUI therefore has no geometry change to report. Keep observing the
/// original event without intercepting normal selection or native scrolling.
struct ConversationScrollIntentProbe: NSViewRepresentable {
    let controller: ConversationScrollAnchorController
    let onScrollIntent: (CGFloat) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.controller = controller
        view.onScrollIntent = onScrollIntent
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.controller = controller
        view.onScrollIntent = onScrollIntent
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        weak var controller: ConversationScrollAnchorController?
        var onScrollIntent: (CGFloat) -> Void = { _ in }
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEvent(event)
                return event
            }
        }

        func stopMonitoring() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }

        func handleScrollEvent(_ event: NSEvent) {
            guard event.type == .scrollWheel, event.scrollingDeltaY != 0,
                abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
                let window, event.windowNumber == window.windowNumber,
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
