import AppKit
import WebKit

/// Links the visible Markdown panes by document progress. Only user scrolling
/// drives synchronization; layout changes and reflected updates never bounce.
@MainActor
final class MarkdownScrollCoordinator: NSObject {
    enum NativePane { case source, rich }
    private weak var source: NSScrollView?
    private weak var rich: NSScrollView?
    private weak var preview: WKWebView?
    private var previewScroll: ((Double, String) -> Void)?
    private var enabled = true
    private var richEditing = false
    private var applying = false
    private var sourceTarget: Double?
    private var richTarget: Double?
    private var sequence = 0

    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(enabled: Bool, richEditing: Bool) {
        guard self.enabled != enabled || self.richEditing != richEditing else { return }
        self.enabled = enabled
        self.richEditing = richEditing
        sourceTarget = nil
        richTarget = nil
    }

    func attachSource(_ view: NSScrollView) {
        guard source !== view else { return }
        observe(view, replacing: source)
        source = view
    }

    func attachRich(_ view: NSScrollView) {
        guard rich !== view else { return }
        observe(view, replacing: rich)
        rich = view
    }

    func attachPreview(_ view: WKWebView, scroll: @escaping (Double, String) -> Void) {
        preview = view
        previewScroll = scroll
    }

    func detachPreview(_ view: WKWebView) {
        guard preview === view else { return }
        preview = nil
        previewScroll = nil
    }

    func previewDidScroll(_ progress: Double, view: WKWebView) {
        guard preview === view, enabled, !richEditing, progress.isFinite else { return }
        apply(progress, to: .source)
    }

    private func observe(_ view: NSScrollView, replacing previous: NSScrollView?) {
        if let previous {
            NotificationCenter.default.removeObserver(
                self, name: NSView.boundsDidChangeNotification, object: previous.contentView)
        }
        view.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: view.contentView
        )
    }

    @objc private func boundsChanged(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView else { return }
        if clip === source?.contentView, let source {
            nativeDidScroll(.source, userInitiated: isUserScrolling(source))
        } else if clip === rich?.contentView, let rich {
            nativeDidScroll(.rich, userInitiated: isUserScrolling(rich))
        }
    }

    func nativeDidScroll(_ pane: NativePane, userInitiated: Bool) {
        guard enabled, !applying, pane == .source || richEditing,
            let view = pane == .source ? source : rich, let progress = Self.progress(in: view)
        else { return }
        let target = pane == .source ? sourceTarget : richTarget
        if pane == .source { sourceTarget = nil } else { richTarget = nil }
        guard target.map({ abs($0 - progress) > 0.000_5 }) ?? true, userInitiated else { return }
        if pane == .rich {
            apply(progress, to: .source)
        } else if richEditing {
            apply(progress, to: .rich)
        } else if preview != nil {
            sequence &+= 1
            previewScroll?(progress, String(sequence))
        }
    }

    private func isUserScrolling(_ view: NSScrollView) -> Bool {
        guard let event = NSApp.currentEvent, event.window === view.window,
            ProcessInfo.processInfo.systemUptime - event.timestamp < 0.5
        else { return false }
        switch event.type {
        case .scrollWheel, .leftMouseDown, .leftMouseDragged:
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        case .keyDown:
            guard let responder = view.window?.firstResponder as? NSView else { return false }
            return responder === view || responder.isDescendant(of: view)
        default: return false
        }
    }

    private func apply(_ progress: Double, to pane: NativePane) {
        guard progress.isFinite, let view = pane == .source ? source : rich,
            let limits = Self.scrollLimits(in: view)
        else { return }
        let progress = min(1, max(0, progress))
        if pane == .source { sourceTarget = progress } else { richTarget = progress }
        applying = true
        defer { applying = false }
        view.contentView.scroll(
            to: NSPoint(
                x: view.contentView.bounds.minX,
                y: limits.lowerBound + progress * (limits.upperBound - limits.lowerBound)))
        view.reflectScrolledClipView(view.contentView)
    }

    static func progress(in view: NSScrollView) -> Double? {
        guard let limits = scrollLimits(in: view), limits.upperBound > limits.lowerBound else { return nil }
        return min(
            1, max(0, (view.contentView.bounds.minY - limits.lowerBound) / (limits.upperBound - limits.lowerBound)))
    }

    private static func scrollLimits(in view: NSScrollView) -> ClosedRange<Double>? {
        guard let document = view.documentView else { return nil }
        let minimum = -view.contentInsets.top
        let maximum = max(minimum, document.frame.maxY + view.contentInsets.bottom - view.contentView.bounds.height)
        return minimum...maximum
    }
}
