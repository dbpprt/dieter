import AppKit
import Testing
import WebKit
@testable import DieterMac

@MainActor
struct MarkdownScrollCoordinatorTests {
    @Test func previewAndSourceFollowProgressWithoutReflectingAnUpdate() throws {
        let source = scrollView(height: 1500)
        let preview = WKWebView()
        let coordinator = MarkdownScrollCoordinator()
        coordinator.attachSource(source)
        var outgoing: [Double] = []
        coordinator.attachPreview(preview) { progress, _ in outgoing.append(progress) }
        source.contentView.scroll(to: .init(x: 0, y: 600))
        coordinator.nativeDidScroll(.source, userInitiated: true)
        #expect(outgoing.count == 1)
        #expect(abs(try #require(outgoing.first) - 0.5) < 0.001)

        coordinator.previewDidScroll(0.8, view: preview)
        #expect(abs(try #require(MarkdownScrollCoordinator.progress(in: source)) - 0.8) < 0.001)
        coordinator.nativeDidScroll(.source, userInitiated: true)
        #expect(outgoing.count == 1)
        // Layout-driven offsets are not user scrolls and never become leaders.
        source.contentView.scroll(to: .init(x: 0, y: 100))
        coordinator.nativeDidScroll(.source, userInitiated: false)
        #expect(outgoing.count == 1)
    }

    @Test func richEditingSynchronizesNativePanesAndIgnoresHiddenPreview() throws {
        let source = scrollView(height: 1500)
        let rich = scrollView(height: 2100)
        let preview = WKWebView()
        let coordinator = MarkdownScrollCoordinator()
        coordinator.attachSource(source)
        coordinator.attachRich(rich)
        var outgoing = 0
        coordinator.attachPreview(preview) { _, _ in outgoing += 1 }
        coordinator.configure(enabled: true, richEditing: true)
        source.contentView.scroll(to: .init(x: 0, y: 600))
        coordinator.nativeDidScroll(.source, userInitiated: true)
        #expect(abs(try #require(MarkdownScrollCoordinator.progress(in: rich)) - 0.5) < 0.001)
        coordinator.previewDidScroll(0, view: preview)
        #expect(abs(try #require(MarkdownScrollCoordinator.progress(in: source)) - 0.5) < 0.001)
        rich.contentView.scroll(to: .init(x: 0, y: 1800))
        coordinator.nativeDidScroll(.rich, userInitiated: true)
        #expect(abs(try #require(MarkdownScrollCoordinator.progress(in: source)) - 1) < 0.001)
        #expect(outgoing == 0)
    }

    @Test func collapsedPanesStaleViewsAndInvalidValuesCannotMoveTheSource() throws {
        let source = scrollView(height: 1500)
        let preview = WKWebView()
        let stale = WKWebView()
        let coordinator = MarkdownScrollCoordinator()
        coordinator.attachSource(source)
        var outgoing = 0
        coordinator.attachPreview(preview) { _, _ in outgoing += 1 }
        coordinator.previewDidScroll(.nan, view: preview)
        coordinator.previewDidScroll(1, view: stale)
        #expect(MarkdownScrollCoordinator.progress(in: source) == 0)
        coordinator.configure(enabled: false, richEditing: false)
        source.contentView.scroll(to: .init(x: 0, y: 300))
        coordinator.nativeDidScroll(.source, userInitiated: true)
        coordinator.previewDidScroll(1, view: preview)
        #expect(abs(try #require(MarkdownScrollCoordinator.progress(in: source)) - 0.25) < 0.001)
        #expect(outgoing == 0)
        coordinator.configure(enabled: true, richEditing: false)
        coordinator.detachPreview(preview)
        coordinator.previewDidScroll(1, view: preview)
        #expect(abs(try #require(MarkdownScrollCoordinator.progress(in: source)) - 0.25) < 0.001)
        #expect(MarkdownScrollCoordinator.progress(in: scrollView(height: 100)) == nil)
    }

    private func scrollView(height: CGFloat) -> NSScrollView {
        let view = NSScrollView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        view.borderType = .noBorder
        view.documentView = MarkdownScrollTestDocument(frame: .init(x: 0, y: 0, width: 400, height: height))
        view.layoutSubtreeIfNeeded()
        return view
    }
}

private final class MarkdownScrollTestDocument: NSView {
    override var isFlipped: Bool { true }
}
