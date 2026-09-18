import AppKit
import Testing
@testable import DieterMac

@Suite(.serialized) @MainActor struct RemoteDesktopKeyboardCaptureTests {
    @Test func captureRequiresFullscreenFocusedControlAndStopsOnReleaseOrLostControl() throws {
        let fixture = KeyboardCaptureFixture()
        defer { fixture.close() }
        fixture.controller.controlActive = true
        fixture.surface.resumeInput()
        #expect(!fixture.tap.active)
        fixture.surface.fullScreenActive = true
        #expect(fixture.tap.active)
        fixture.controller.controlActive = false
        #expect(!fixture.tap.active)
        fixture.controller.controlActive = true
        #expect(fixture.tap.active)
        fixture.surface.releaseFocus()
        #expect(!fixture.tap.active)
        fixture.surface.resumeInput()
        fixture.controller.controlActive = true
        #expect(fixture.tap.active)
        fixture.surface.captureKeyboard = false
        #expect(!fixture.tap.active)
        #expect(fixture.window.firstResponder === fixture.surface)
    }

    @Test func capturedFullscreenShortcutGoesRemoteAndEscapeAlwaysReleases() throws {
        let fixture = KeyboardCaptureFixture()
        defer { fixture.close() }
        var fullscreenToggles = 0
        var remoteActivity = 0
        fixture.surface.onToggleFullScreen = { fullscreenToggles += 1 }
        fixture.controller.onUserActivity = { remoteActivity += 1 }
        fixture.surface.fullScreenActive = true
        fixture.controller.controlActive = true
        fixture.surface.resumeInput()
        let fullscreen = try key(3, [.command, .control])
        #expect(fixture.tap.receive?(fullscreen) == true)
        #expect(fullscreenToggles == 0)
        #expect(remoteActivity == 1)
        fixture.controller.controlActive = true
        fixture.surface.resumeInput()
        let escape = try key(53, [.command, .shift])
        #expect(fixture.tap.receive?(escape) == true)
        #expect(!fixture.tap.active)
        #expect(!fixture.controller.inputFocused)
        #expect(fixture.window.firstResponder !== fixture.surface)
        #expect(fixture.tap.receive?(fullscreen) == false)
    }

    @Test func tapInterruptionAndPermissionDenialLeaveLocalInputAvailable() throws {
        let fixture = KeyboardCaptureFixture()
        defer { fixture.close() }
        fixture.surface.fullScreenActive = true
        fixture.controller.controlActive = true
        fixture.surface.resumeInput()
        fixture.tap.interrupted?()
        #expect(!fixture.tap.active)
        #expect(!fixture.controller.inputFocused)
        fixture.tap.allowed = false
        fixture.window.makeFirstResponder(fixture.surface)
        fixture.controller.controlActive = true
        fixture.surface.resumeInput()
        #expect(!fixture.tap.active)
        #expect(fixture.controller.keyboardCaptureStatus.contains("Accessibility"))
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
    }
}

@MainActor private final class KeyboardCaptureFixture {
    let controller = RemoteDesktopController()
    let tap = FixtureKeyboardTap()
    let surface: RemoteDesktopInputView
    let window: NSWindow
    init() {
        _ = NSApplication.shared
        surface = RemoteDesktopInputView(renderer: controller.renderer, controller: controller, keyboardCapture: tap)
        window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 800, height: 600), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        surface.windowIsActive = { $0 != nil }
        window.makeFirstResponder(surface)
    }
    func close() { surface.releaseFocus(); controller.disconnect(); window.contentView = nil; window.close() }
}

@MainActor private final class FixtureKeyboardTap: RemoteDesktopKeyboardCapturing {
    var receive: ((NSEvent) -> Bool)?
    var interrupted: (() -> Void)?
    var active = false
    var allowed = true
    func start() -> Bool { active = allowed; return active }
    func stop() { active = false }
}
