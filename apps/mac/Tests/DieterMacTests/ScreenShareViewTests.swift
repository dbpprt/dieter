import AppKit
import SwiftUI
import Testing
@preconcurrency import WebRTC
@testable import DieterMac

@Suite(.serialized) @MainActor
struct ScreenShareViewTests {
    @Test func switchingMachinesKeepsVideoInputAndClipboardOnTheSelectedSession() async throws {
        let fixture = try ScreenShareViewFixture()
        defer { fixture.close() }
        await fixture.settle()

        for session in [fixture.first, fixture.second, fixture.first, fixture.second] {
            let previous = fixture.model.selectedSession
            let previousSurface = fixture.surface
            fixture.window.makeFirstResponder(previousSurface)
            fixture.model.selectSession(session.id)
            await fixture.settle()
            let surface = try #require(fixture.surface)
            #expect(surface.controller === session.controller)
            #expect(surface.renderer === session.controller.renderer)
            #expect(session.controller.renderer.superview === surface)
            #expect(session.controller.clipboardVisible)
            #expect(session.controller.clipboardWindow === fixture.window)
            #expect(fixture.model.connectedCount == 2)
            if let previous, previous !== session {
                #expect(previousSurface?.window == nil)
                #expect(!previous.controller.inputFocused)
                #expect(!previous.controller.clipboardVisible)
                #expect(previous.controller.clipboardWindow == nil)
            }
        }

        fixture.model.closeSession(fixture.second.id)
        await fixture.settle()
        #expect(fixture.surface?.controller === fixture.first.controller)
        #expect(fixture.surface?.renderer === fixture.first.controller.renderer)
        #expect(fixture.first.controller.phase == .streaming)
    }

    @Test func reattachingInputGetsTheRetainedVideoDimensionsWithoutAnotherFrame() async {
        let renderer = RemoteDesktopMetalView(frame: .zero)
        let first = ScreenSizeObserver()
        renderer.delegate = first
        renderer.setSize(CGSize(width: 1200, height: 1920))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(first.size == CGSize(width: 1200, height: 1920))
        let second = ScreenSizeObserver()
        renderer.delegate = second
        #expect(second.size == first.size)
        renderer.reset()
        let third = ScreenSizeObserver()
        renderer.delegate = third
        #expect(third.size == nil)
    }
}

@MainActor
private final class ScreenSizeObserver: NSObject, @preconcurrency RTCVideoViewDelegate {
    var size: CGSize?
    func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) { self.size = size }
}

@MainActor
private final class ScreenShareViewFixture {
    let defaults: UserDefaults
    let suite = "dieter-screen-view-" + UUID().uuidString
    let model: ScreensModel
    let first = ScreenShareSession(id: "view-alpha", machineID: "alpha", machineName: "Alpha", monitorsInactivity: false)
    let second = ScreenShareSession(id: "view-beta", machineID: "beta", machineName: "Beta", monitorsInactivity: false)
    let root: NSView
    let window: NSWindow

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        model = ScreensModel(defaults: defaults)
        model.sessions = [first, second]
        model.selectedSessionID = first.id
        first.controller.phase = .streaming
        second.controller.phase = .streaming
        let host = NSHostingView(rootView: ScreensView(
            model: model, machines: [], initialMachineID: "alpha",
            makeConnection: { _ in throw CancellationError() }))
        host.sizingOptions = []
        root = host
        window = NSWindow(
            contentRect: NSRect(x: -3_000, y: -3_000, width: 1000, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
    }

    var surface: RemoteDesktopInputView? {
        descendants(root).compactMap { $0 as? RemoteDesktopInputView }.first
    }

    func settle() async {
        root.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        root.layoutSubtreeIfNeeded()
    }

    func close() {
        window.contentView = nil
        window.close()
        first.disconnect()
        second.disconnect()
        defaults.removePersistentDomain(forName: suite)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
