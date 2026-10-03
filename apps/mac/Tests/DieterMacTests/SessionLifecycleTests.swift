import AppKit
import DieterAPI
import Foundation
import SharedCore
import Synchronization
import Testing
@testable import DieterMac

// The screen view's adapter over the shared core's screen session. The
// session itself (trust, the lease, recovery, superseded attempts, input
// sequencing) is covered by the core's ScreenSessionTest; these pin what the
// Mac sends and how it reads the slice back.

@MainActor private func screenCommands(_ core: ScriptedCoreClient) -> [ClientScreenCommand] {
    core.commands.compactMap { if case .screen(let screen)? = $0.command { screen } else { nil } }
}

/// The action's case name, e.g. "pointer".
private func actionName(_ action: ClientScreenCommand.OneOf_Action?) -> String {
    guard let action else { return "" }
    return String(String(describing: action).prefix { $0 != "(" })
}

@Test @MainActor func screenConnectSendsPreferencesViewportAndMachineInOrder() async throws {
    let core = ScriptedCoreClient()
    let controller = RemoteDesktopController(core: core)
    controller.setViewport(CGSize(width: 1280, height: 800), scale: 1)
    controller.inputFocused = true
    await controller.settle()
    #expect(core.commands.isEmpty, "nothing reaches the core before a session is opened")

    controller.connect(daemonID: "daemon-a", machineName: "Studio")
    await controller.settle()
    #expect(core.isObserved(.screen, scope: controller.scope))
    let sent = screenCommands(core)
    #expect(sent.allSatisfy { $0.scope == controller.scope })
    guard sent.count == 3, case .preferences(let preferences)? = sent[0].action,
        case .viewport(let viewport)? = sent[1].action, case .connect(let connect)? = sent[2].action
    else {
        Issue.record("unexpected commands: \(sent)")
        return
    }
    #expect(preferences.codec == .h264 && preferences.maxFps == 60 && preferences.clipboard)
    #expect(viewport.widthPoints == 1280 && viewport.heightPoints == 800 && viewport.scale == 1)
    #expect(connect.daemonID == "daemon-a")
    #expect(controller.machineName == "Studio")
}

@Test @MainActor func screenSliceFoldsPhaseControlCursorAndPreferences() throws {
    let core = ScriptedCoreClient()
    let controller = RemoteDesktopController(core: core)
    controller.connect(daemonID: "daemon-a", machineName: "Studio")
    var cursorChanges = 0
    controller.onCursorChange = { cursorChanges += 1 }

    core.emit(.screen, scope: controller.scope) {
        $0.screen = .with {
            $0.phase = "permission_required"
            $0.problem = "Grant Screen Recording on the host"
        }
    }
    #expect(controller.phase == .permissionRequired("Grant Screen Recording on the host"))
    #expect(controller.errorMessage == nil)

    let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
        NSColor.red.setFill(); rect.fill(); return true
    }
    let png = try #require(
        image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
    core.emit(.screen, scope: controller.scope) {
        $0.screen = .with {
            $0.phase = "streaming"
            $0.phaseLabel = "Live"
            $0.active = true
            $0.frameRates = [30, 60, 90, 120]
            $0.controlActive = true
            $0.canTransferControl = true
            $0.routeLabel = "Direct"
            $0.capabilities = .with {
                $0.maxFps = 120; $0.platform = "darwin"; $0.clipboardSupported = true
            }
            $0.state = .with {
                $0.codec = "H264"; $0.displayGeneration = 3; $0.controlActive = true
            }
            $0.cursorImage = png
            $0.cursorWidth = 16
            $0.cursorHeight = 16
            $0.cursorHotspotX = 2
            $0.cursorHotspotY = 3
            $0.cursorVisible = true
            $0.cursorX = 0.25
            $0.cursorY = 0.75
            $0.clipboardEnabled = true
            $0.preferences = .with {
                $0.codec = .auto; $0.maxFps = 90; $0.quality = .detail
            }
            $0.displayStatus = "Matched: 1512 × 982"
        }
    }
    #expect(controller.phase == .streaming)
    #expect(controller.controlActive && controller.canTransferControl)
    #expect(controller.controlUnavailableReason.isEmpty)
    #expect(controller.active)
    #expect(controller.routeLabel == "Direct")
    #expect(controller.sessionState.displayGeneration == 3)
    #expect(controller.frameRates == [30, 60, 90, 120])
    #expect(controller.phaseLabel == "Live")
    #expect(controller.remoteCursor.image.size == NSSize(width: 16, height: 16))
    #expect(controller.remoteCursor.hotSpot == NSPoint(x: 2, y: 3))
    #expect(controller.remoteCursorState == RemoteDesktopCursorState(visible: true, x: 0.25, y: 0.75))
    #expect(controller.codecPreference == .auto && controller.preferredMaxFPS == 90 && controller.quality == .detail)
    #expect(controller.displayMatchingStatus == "Matched: 1512 × 982")
    #expect(cursorChanges >= 2)

    // An unchanged cursor image is left out; the shape stays.
    let shape = controller.remoteCursor
    core.emit(.screen, scope: controller.scope) {
        $0.screen = .with {
            $0.phase = "streaming"
            $0.active = true
            $0.cursorImageUnchanged = true
            $0.cursorVisible = true
            $0.capabilities = .with { $0.platform = "linux" }
            $0.controlUnavailableReason = "Remote-control permission is required from the Linux desktop portal"
        }
    }
    #expect(controller.remoteCursor === shape)
    #expect(!controller.controlActive)
    #expect(controller.controlUnavailableReason.contains("Linux desktop portal"))

    core.emit(.screen, scope: controller.scope) {
        $0.screen = .with {
            $0.phase = "failed"
            $0.problem = "The enrolled machine identity changed."
        }
    }
    #expect(controller.phase == .failed("The enrolled machine identity changed."))
    #expect(controller.errorMessage == "The enrolled machine identity changed.")
    #expect(controller.mediaRouteLabel == "Negotiating media")
}

@Test @MainActor func screenInputMapsAppKitEventsToCoreCommands() async throws {
    let core = ScriptedCoreClient()
    let controller = RemoteDesktopController(core: core)
    var activity = 0
    controller.onUserActivity = { activity += 1 }
    controller.connect(daemonID: "daemon-a", machineName: "Studio")
    await controller.settle()
    let opened = core.commands.count

    // Pointer motion is dropped until the core reports control.
    controller.sendPointerMove(x: 0.5, y: 0.5)
    controller.releaseAllInput()
    await controller.settle()
    #expect(core.commands.count == opened)

    core.emit(.screen, scope: controller.scope) {
        $0.screen = .with {
            $0.phase = "streaming"
            $0.controlActive = true
            $0.canTransferControl = true
            $0.clipboardEnabled = true
        }
    }
    controller.sendPointerMove(x: 0.25, y: 0.75)
    controller.sendPointerButton(.left, down: true, clickCount: 5, x: 0.25, y: 0.75, modifiers: [.command, .shift])
    controller.sendScroll(
        deltaX: 1.5, deltaY: -4.25, precise: true, modifiers: [.option], phase: [.began], momentumPhase: [.ended])
    controller.sendKey(code: 0, down: true, repeat: true, modifiers: [.control, .capsLock])
    controller.sendKey(code: 999, down: true, repeat: false, modifiers: [])
    controller.sendText("héllo")
    controller.releaseAllInput()
    controller.transferControl(take: false)
    #expect(controller.controlTransferPending)
    controller.transferControl(take: true)
    controller.performClipboard("copy")
    controller.setDisplayMatchingTarget(.init(width: 1512, height: 982, scale: 2, refresh: 120))
    controller.setDisplayMatchingTarget(nil)
    controller.configure(quality: .motion, maxFPS: 500, refresh: true)
    await controller.settle()

    let sent = screenCommands(core).dropFirst(opened).map(\.action)
    let expected: [String] = [
        "pointer", "button", "scroll", "key", "text", "releaseInput", "control", "clipboard", "matchDisplay",
        "matchDisplay", "preferences", "refresh",
    ]
    let names: [String] = sent.map(actionName)
    #expect(names == expected)
    guard case .pointer(let pointer)? = sent[0], case .button(let button)? = sent[1],
        case .scroll(let scroll)? = sent[2],
        case .key(let key)? = sent[3], case .text(let text)? = sent[4], case .control(let control)? = sent[6],
        case .clipboard(let clipboard)? = sent[7], case .matchDisplay(let match)? = sent[8],
        case .matchDisplay(let stop)? = sent[9], case .preferences(let preferences)? = sent[10]
    else {
        Issue.record("unexpected commands: \(sent)")
        return
    }
    #expect(pointer.x == 0.25 && pointer.y == 0.75)
    #expect(button.button == .left && button.down && button.clicks == 3 && button.modifiers == 9)
    #expect(scroll.dx == 1.5 && scroll.dy == -4.25 && scroll.precise && scroll.phase == 1 && scroll.momentum == 3)
    #expect(scroll.modifiers == 4)
    #expect(key.hid == 4 && key.down && key.repeat && key.modifiers == 18, "the A key is HID usage 4")
    #expect(text.text == "héllo")
    #expect(!control.on, "a transfer in flight is not repeated")
    #expect(clipboard.operation == "copy")
    #expect(match.width == 1512 && match.height == 982 && match.scale == 2 && match.refresh == 120)
    #expect(stop.width == 0 && stop.height == 0, "an empty target stops matching")
    #expect(preferences.quality == .motion && preferences.maxFps == 60, "the frame rate stays within the host's")
    #expect(activity >= 8)
}

@Test @MainActor func screenWakeResumesOnlyAnOpenSession() async throws {
    let core = ScriptedCoreClient()
    let controller = RemoteDesktopController(core: core)
    let session = ScreenShareSession(
        machineID: "origin#wake", daemonID: "wake", machineName: "Fixture", controller: controller,
        monitorsInactivity: false)
    session.configureInactivityTimeout(enabled: true, minutes: 1)
    session.connect()
    controller.phase = .streaming
    controller.active = true
    func count(_ name: String) -> Int {
        screenCommands(core).filter { actionName($0.action) == name }.count
    }

    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
    #expect(controller.systemSleeping)
    #expect(!session.disconnectIfInactive(at: Date().addingTimeInterval(3600)))
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    await controller.settle()
    #expect(!controller.systemSleeping)
    #expect(count("sleep") == 1 && count("resume") == 1)

    session.disconnect()
    #expect(controller.phase == .idle)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    await controller.settle()
    #expect(count("resume") == 1, "a closed tab does not reopen on wake")
    #expect(count("disconnect") == 1)

    session.close()
    await controller.settle()
    #expect(!core.isObserved(.screen, scope: controller.scope), "closing the tab releases the core's screen")
}
