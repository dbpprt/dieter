import AppKit
import Observation
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func contentSplitPreservesNativeTranscriptAcrossOpenResizeAndClose() async throws {
    let state = ContentSplitFixtureState()
    let host = NSHostingView(rootView: ContentSplitFixture(state: state))
    host.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let mounted = await waitForContentSplit { nativeTranscript(host) != nil }
    #expect(mounted)
    let transcript = try #require(nativeTranscript(host))
    let originalWidth = transcript.frame.width
    let selection = NSRange(location: 6, length: 19)
    transcript.setSelectedRange(selection)

    state.presented = true
    let opened = await waitForContentSplit {
        guard let split = nativeSplit(host), split.arrangedSubviews.count == 2 else { return false }
        return split.arrangedSubviews[0].frame.width >= 280 && split.arrangedSubviews[1].frame.width >= 300
            && transcript.frame.width < originalWidth - 100
    }
    #expect(opened)
    #expect(nativeTranscript(host) === transcript)
    #expect(transcript.selectedRange() == selection)
    let split = try #require(nativeSplit(host))
    let targetWidth: CGFloat = 400
    split.setPosition(targetWidth, ofDividerAt: 0)
    let resized = await waitForContentSplit { abs(split.arrangedSubviews[0].frame.width - targetWidth) < 2 }
    #expect(resized)
    #expect(nativeTranscript(host) === transcript)
    #expect(transcript.selectedRange() == selection)

    state.presented = false
    let closed = await waitForContentSplit {
        nativeSplit(host)?.arrangedSubviews.count == 1 && abs(transcript.frame.width - originalWidth) < 2
    }
    #expect(closed)
    #expect(nativeTranscript(host) === transcript)
    #expect(transcript.selectedRange() == selection)
}

@MainActor @Observable private final class ContentSplitFixtureState {
    var presented = false
}

private struct ContentSplitFixture: View {
    let state: ContentSplitFixtureState
    var body: some View {
        ConversationContentSplit(presented: state.presented) {
            ScrollView {
                SelectableMessageText(
                    source: "First paragraph with a selected phrase.\n\n"
                        + String(repeating: "More selectable text. ", count: 100),
                    color: .primary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } content: {
            Text("Content pane").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor private func nativeTranscript(_ view: NSView) -> MessageTextView? {
    (view as? MessageTextView) ?? view.subviews.lazy.compactMap { nativeTranscript($0) }.first
}

@MainActor private func nativeSplit(_ view: NSView) -> NSSplitView? {
    (view as? NSSplitView) ?? view.subviews.lazy.compactMap { nativeSplit($0) }.first
}

@MainActor private func waitForContentSplit(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
