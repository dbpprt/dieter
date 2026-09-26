import AppKit
import SwiftUI
import Testing
@preconcurrency import WebRTC
@testable import DieterMac

@Suite(.serialized) @MainActor
struct ScreenShareViewTests {
    @Test func presentationSubviewsDoNotInterceptClicksAndActivationClickReachesDesktop() throws {
        let controller = RemoteDesktopController()
        defer { controller.disconnect() }
        let surface = RemoteDesktopInputView(renderer: controller.renderer, controller: controller)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = surface
        surface.layoutSubtreeIfNeeded(); surface.layout()
        // Reproduce a visible cursor image over the desktop, including inactive
        // windows where it remains visible until the activation click.
        let cursor = NSImageView(frame: NSRect(x: 390, y: 290, width: 24, height: 24))
        surface.addSubview(cursor)
        #expect(surface.hitTest(NSPoint(x: 400, y: 300)) === surface)
        #expect(surface.hitTest(NSPoint(x: -1, y: 300)) == nil)
        func event(_ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1))
        }
        controller.phase = .streaming
        #expect(surface.acceptsFirstMouse(for: try event(NSPoint(x: 400, y: 300))))
        #expect(!surface.acceptsFirstMouse(for: try event(NSPoint(x: 400, y: 5))))
        controller.phase = .reconnecting
        #expect(!surface.acceptsFirstMouse(for: try event(NSPoint(x: 400, y: 300))))
    }

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

    @Test func undockingMovesOneSurfaceAndClosingTheWindowReturnsItWithoutDisconnecting() async throws {
        let fixture = try ScreenShareViewFixture()
        defer { fixture.close() }
        await fixture.settle()
        let surface = try #require(fixture.surface)
        fixture.model.undock(fixture.first.id, fullScreen: false)
        await fixture.settle()
        let viewer = try #require(fixture.model.detachedWindows[fixture.first.id])
        #expect(fixture.first.isDetached)
        #expect(fixture.surface == nil)
        #expect(fixture.first.videoSurface === surface)
        #expect(surface.window === viewer.window)
        #expect(surface.renderer === fixture.first.controller.renderer)
        #expect(fixture.first.controller.clipboardWindow === viewer.window)
        fixture.model.undock(fixture.first.id, fullScreen: false)
        #expect(fixture.model.detachedWindows.count == 1)
        fixture.model.selectSession(fixture.second.id)
        await fixture.settle()
        #expect(fixture.surface?.controller === fixture.second.controller)
        #expect(surface.window === viewer.window)
        viewer.window?.performClose(nil)
        await fixture.settle()
        #expect(fixture.model.detachedWindows.isEmpty)
        #expect(!fixture.first.isDetached)
        #expect(fixture.surface === surface)
        #expect(fixture.first.controller.clipboardWindow === fixture.window)
        #expect(fixture.first.controller.phase == .streaming)
        #expect(fixture.second.controller.phase == .streaming)
        fixture.model.undock(fixture.first.id, fullScreen: false)
        await fixture.settle()
        let detached = fixture.model.detachedWindows[fixture.first.id]?.window
        fixture.model.closeSession(fixture.first.id)
        await fixture.settle()
        #expect(detached?.isVisible == false)
        #expect(fixture.model.detachedWindows.isEmpty)
        #expect(fixture.second.controller.phase == .streaming)
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

    @Test func viewOnlyFullScreenShortcutBelongsToTheViewer() async throws {
        let fixture = try ScreenShareViewFixture()
        defer { fixture.close() }
        await fixture.settle()
        let surface = try #require(fixture.surface)
        #expect(!fixture.first.controller.controlActive)
        #expect(fixture.window.makeFirstResponder(surface))
        var toggled = false
        surface.onToggleFullScreen = { toggled = true }
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control, .command], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, characters: "f",
                charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        #expect(surface.performKeyEquivalent(with: event))
        #expect(toggled, "View-only mode must not send the shortcut to the main app's fullscreen menu")
        #expect(fixture.first.controller.eventOrdinal == 0)
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
    let first = ScreenShareSession(
        id: "view-alpha", machineID: "alpha", machineName: "Alpha", monitorsInactivity: false)
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
        let host = NSHostingView(
            rootView: ScreensView(
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
        model.closeSession(first.id)
        model.closeSession(second.id)
        defaults.removePersistentDomain(forName: suite)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@Test func screenCursorOwnershipHasOnePointerWithoutWaitingForRemoteMotion() {
    // Keyboard focus is deliberately absent from the policy. Hover movement
    // controls the host immediately and must never show its delayed overlay.
    #expect(
        RemoteDesktopCursorPresentation.resolve(
            controlling: true, active: true, inside: true, embedded: false, remoteVisible: true) == .local)
    #expect(
        RemoteDesktopCursorPresentation.resolve(
            controlling: true, active: true, inside: true, embedded: false, remoteVisible: false) == .local)
    #expect(
        RemoteDesktopCursorPresentation.resolve(
            controlling: false, active: true, inside: true, embedded: false, remoteVisible: true) == .remote)
    #expect(
        RemoteDesktopCursorPresentation.resolve(
            controlling: true, active: false, inside: true, embedded: false, remoteVisible: true) == .remote)
    #expect(
        RemoteDesktopCursorPresentation.resolve(
            controlling: true, active: true, inside: false, embedded: false, remoteVisible: true) == .remote)
    #expect(
        RemoteDesktopCursorPresentation.resolve(
            controlling: true, active: true, inside: true, embedded: true, remoteVisible: true) == .embedded)
    #expect(
        RemoteDesktopCursorPresentation.resolve(
            controlling: false, active: true, inside: true, embedded: false, remoteVisible: false) == .local)
}
