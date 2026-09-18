import AppKit
@preconcurrency import ApplicationServices
import Carbon

// The tap runs on AppKit's run loop and consumes events before local shortcuts
// reach menus or the Dock. It never waits for the network or queues another frame.
@MainActor protocol RemoteDesktopKeyboardCapturing: AnyObject {
    var active: Bool { get }
    var receive: ((NSEvent) -> Bool)? { get set }
    var interrupted: (() -> Void)? { get set }
    func start() -> Bool
    func stop()
}

@MainActor final class RemoteDesktopKeyboardCapture: RemoteDesktopKeyboardCapturing {
    static let injectedEventTag: Int64 = 0x444945544552
    private static weak var owner: RemoteDesktopKeyboardCapture?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var healthTimer: Timer?
    private var permissionRetryAt: TimeInterval = 0
    private var previousPresentation: NSApplication.PresentationOptions?
    var receive: ((NSEvent) -> Bool)?
    var interrupted: (() -> Void)?
    var active: Bool { tap != nil }

    static func requestPermission() {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    func start() -> Bool {
        if active { return true }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= permissionRetryAt else { return false }
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            // Pointer/cursor updates can run hundreds of times a second. A
            // denied grant must not put a TCC query on each input event.
            permissionRetryAt = now + 1
            return false
        }
        Self.owner?.stop()
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let consumed = MainActor.assumeIsolated {
                        let capture = Unmanaged<RemoteDesktopKeyboardCapture>.fromOpaque(context).takeUnretainedValue()
                        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                            capture.stop()
                            capture.interrupted?()
                            return false
                        }
                        // Same-machine sessions must never recapture their own injected keys.
                        guard
                            event.getIntegerValueField(.eventSourceUserData)
                                != RemoteDesktopKeyboardCapture.injectedEventTag,
                            let key = NSEvent(cgEvent: event), capture.receive?(key) == true
                        else { return false }
                        return true
                    }
                    return consumed ? nil : Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        else { return false }
        self.tap = tap; self.source = source; Self.owner = self
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        previousPresentation = NSApp.presentationOptions
        var options = NSApp.presentationOptions
        if !options.contains(.hideDock) { options.insert(.autoHideDock) }
        options.insert(.disableProcessSwitching)
        NSApp.presentationOptions = options
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tap = self.tap else { return }
                if !AXIsProcessTrusted() || IsSecureEventInputEnabled() || !CGEvent.tapIsEnabled(tap: tap) {
                    self.stop(); self.interrupted?()
                }
            }
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func stop() {
        healthTimer?.invalidate(); healthTimer = nil
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopSourceInvalidate(source) }
        tap = nil; source = nil
        if let previousPresentation {
            NSApp.presentationOptions = previousPresentation
            self.previousPresentation = nil
        }
        if Self.owner === self { Self.owner = nil }
    }
}
