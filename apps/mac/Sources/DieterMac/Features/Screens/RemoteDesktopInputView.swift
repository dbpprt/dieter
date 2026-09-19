import AppKit
import DieterAPI
@preconcurrency import WebRTC

@MainActor
final class RemoteDesktopInputView: NSView, @preconcurrency NSTextInputClient, @preconcurrency RTCVideoViewDelegate {
    let renderer: RemoteDesktopMetalView
    private(set) weak var controller: RemoteDesktopController?
    private var videoSize = CGSize(width: 16, height: 9)
    private var trackingAreaReference: NSTrackingArea?
    private var buttonsDown = Set<Int>()
    private var modifierKeysDown = Set<UInt16>()
    private var physicalKeysDown = Set<UInt16>()
    private var markedText = NSAttributedString(string: "")
    private var markedSelection = NSRange(location: NSNotFound, length: 0)
    private let focusObserverBag = RemoteDesktopFocusObservers()
    private let hostCursorView = NSImageView()
    var onToggleFullScreen: (@MainActor () -> Void)?
    var fullScreenActive = false { didSet { refreshKeyboardCapture() } }
    var captureKeyboard = true { didSet { refreshKeyboardCapture() } }
    private let keyboardCapture: any RemoteDesktopKeyboardCapturing
    private var forwardingCapturedKey = false
    var keyboardCaptured: Bool { keyboardCapture.active }
    // The native integration fixture has no NSApplication.run loop; packaged
    // UI tests exercise the default AppKit activation predicate independently.
    var windowIsActive: @MainActor (NSWindow?) -> Bool = { $0?.isKeyWindow == true && NSApp.isActive }
    private var inputSuspended = false
    private var lastAppliedCursor: NSCursor?
    private(set) var cursorPresentation = RemoteDesktopCursorPresentation.local
    var hostCursorVisible: Bool { !hostCursorView.isHidden }
    var videoContentRect: CGRect { convert(renderer.contentRect(videoSize: videoSize), from: renderer) }
    private static let invisibleCursor = NSCursor(
        image: NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true }, hotSpot: .zero)

    init(
        renderer: RemoteDesktopMetalView, controller: RemoteDesktopController,
        keyboardCapture: any RemoteDesktopKeyboardCapturing = RemoteDesktopKeyboardCapture()
    ) {
        self.renderer = renderer
        self.controller = controller
        self.keyboardCapture = keyboardCapture
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        renderer.delegate = self
        addSubview(renderer)
        hostCursorView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(hostCursorView)
        hostCursorView.isHidden = true
        controller.onCursorChange = { [weak self] in self?.refreshCursor() }
        keyboardCapture.receive = { [weak self] event in self?.receiveCapturedKey(event) ?? false }
        keyboardCapture.interrupted = { [weak self] in self?.suspendInput() }
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.clipboardWindow = window
        controller?.clipboardVisible = window != nil
        focusObserverBag.tokens.forEach(NotificationCenter.default.removeObserver)
        focusObserverBag.tokens.removeAll()
        for (name, object) in [
            (NSApplication.didResignActiveNotification, NSApp as AnyObject?),
            (NSWindow.didResignKeyNotification, window as AnyObject?),
        ] {
            focusObserverBag.tokens.append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.releaseFocus() }
                })
        }
        for (name, object) in [
            (NSApplication.didBecomeActiveNotification, NSApp as AnyObject?),
            (NSWindow.didBecomeKeyNotification, window as AnyObject?),
        ] {
            focusObserverBag.tokens.append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshCursor() }
                })
        }
        if window == nil { releaseFocus() }
        refreshCursor()
    }
    override func becomeFirstResponder() -> Bool {
        inputSuspended = false
        controller?.inputFocused = true
        refreshCursor()
        return super.becomeFirstResponder()
    }
    func releaseFocus() {
        keyboardCapture.stop()
        controller?.inputFocused = false
        controller?.releaseAllInput()
        buttonsDown.removeAll(); modifierKeysDown.removeAll(); physicalKeysDown.removeAll()
        unmarkText()
        refreshCursor()
    }
    func refreshCursor(at point: CGPoint? = nil) {
        guard let controller else { return }
        refreshKeyboardCapture()
        let rect = videoContentRect
        let location =
            point ?? window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? CGPoint(x: -1, y: -1)
        let inside = rect.contains(location)
        let active = windowIsActive(window)
        let state = controller.remoteCursorState
        cursorPresentation = .resolve(
            controlling: controller.controlActive && !inputSuspended,
            active: active,
            inside: inside, embedded: controller.sessionState.embeddedCursor, remoteVisible: state.visible)
        let local =
            cursorPresentation == .local && controller.controlActive && !inputSuspended
            ? controller.remoteCursor : NSCursor.arrow
        let desired = cursorPresentation == .local ? local : Self.invisibleCursor
        if lastAppliedCursor !== desired {
            lastAppliedCursor = desired
            window?.invalidateCursorRects(for: self)
        }
        if inside && active { desired.set() }
        hostCursorView.isHidden =
            controller.sessionState.embeddedCursor || !state.visible
            || (cursorPresentation == .local && inside && controller.controlActive && !inputSuspended && active)
        guard !hostCursorView.isHidden else { return }
        let cursor = controller.remoteCursor
        hostCursorView.image = cursor.image
        hostCursorView.frame = NSRect(
            x: rect.minX + rect.width * Double(state.normalizedX) / 1_000_000 - cursor.hotSpot.x,
            y: rect.maxY - rect.height * Double(state.normalizedY) / 1_000_000 - cursor.image.size.height
                + cursor.hotSpot.y,
            width: cursor.image.size.width, height: cursor.image.size.height)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = videoContentRect
        if !rect.isEmpty { addCursorRect(rect, cursor: lastAppliedCursor ?? .arrow) }
    }
    override func layout() {
        super.layout()
        renderer.frame = bounds
        renderer.layout()
        controller?.setViewport(renderer.drawablePixelSize, scale: 1)
        refreshCursor()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderer.layout()
        controller?.setViewport(renderer.drawablePixelSize, scale: 1)
        refreshCursor()
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        videoSize = size.width > 0 && size.height > 0 ? size : videoSize
        refreshCursor()
    }

    override func mouseEntered(with event: NSEvent) { refreshCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set(); refreshCursor(at: CGPoint(x: -1, y: -1)) }
    override func cursorUpdate(with event: NSEvent) { refreshCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { sendMove(event) }
    override func mouseDragged(with event: NSEvent) { sendMove(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMove(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMove(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        resumeInput()
        sendButton(.left, down: true, event: event)
    }
    override func mouseUp(with event: NSEvent) { sendButton(.left, down: false, event: event) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        resumeInput()
        sendButton(.right, down: true, event: event)
    }
    override func rightMouseUp(with event: NSEvent) { sendButton(.right, down: false, event: event) }
    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        resumeInput()
        sendButton(button(event.buttonNumber), down: true, event: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        sendButton(button(event.buttonNumber), down: false, event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !inputSuspended, windowIsActive(window) else { return }
        controller?.sendScroll(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas, modifiers: event.modifierFlags, phase: event.phase,
            momentumPhase: event.momentumPhase)
    }

    override func keyDown(with event: NSEvent) {
        guard !isInjectedKey(event) else { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !keyboardCaptured && !forwardingCapturedKey && event.keyCode == 3 && modifiers == [.command, .control] {
            if !event.isARepeat { releaseFocus(); onToggleFullScreen?() }
            return
        }
        if [7, 8, 9].contains(event.keyCode),
            event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
            controller?.capabilities.clipboardSupported == true, controller?.clipboardEnabled == true
        {
            if !event.isARepeat {
                switch event.keyCode {
                case 7: controller?.clipboard.cut()
                case 8: controller?.clipboard.copySelection()
                default: controller?.clipboard.paste()
                }
            }
            return
        }
        if event.keyCode == 53 && event.modifierFlags.contains([.command, .shift]) {
            suspendInput()
            return
        }
        if controller?.textInputMode == true, !event.modifierFlags.contains(.command),
            !event.modifierFlags.contains(.control)
        {
            interpretKeyEvents([event])
            return
        }
        physicalKeysDown.insert(event.keyCode)
        controller?.sendKey(
            code: event.keyCode, down: true, repeat: event.isARepeat,
            modifiers: event.modifierFlags)
    }
    override func keyUp(with event: NSEvent) {
        guard !isInjectedKey(event) else { return }
        guard physicalKeysDown.remove(event.keyCode) != nil else { return }
        controller?.sendKey(
            code: event.keyCode, down: false, repeat: false, modifiers: event.modifierFlags)
    }
    override func flagsChanged(with event: NSEvent) {
        guard !isInjectedKey(event) else { return }
        let down: Bool
        if event.keyCode == 57 {
            down = event.modifierFlags.contains(.capsLock)
        } else {
            down =
                !modifierKeysDown.contains(event.keyCode)
                && modifierIsDown(keyCode: event.keyCode, flags: event.modifierFlags)
        }
        if down { modifierKeysDown.insert(event.keyCode) } else { modifierKeysDown.remove(event.keyCode) }
        controller?.sendKey(
            code: event.keyCode, down: down, repeat: false, modifiers: event.modifierFlags)
    }
    override func resignFirstResponder() -> Bool {
        releaseFocus()
        return super.resignFirstResponder()
    }

    private var canCaptureKeyboard: Bool {
        captureKeyboard && fullScreenActive && !inputSuspended && windowIsActive(window)
            && window?.firstResponder === self && controller?.inputFocused == true && controller?.controlActive == true
    }

    func refreshKeyboardCapture() {
        if controller?.controlActive != true {
            modifierKeysDown.removeAll(); physicalKeysDown.removeAll(); buttonsDown.removeAll()
        }
        guard canCaptureKeyboard else {
            keyboardCapture.stop()
            setKeyboardCaptureStatus("")
            return
        }
        setKeyboardCaptureStatus(
            keyboardCapture.start()
                ? "Keyboard captured · ⌘⇧Esc releases input"
                : "Enable Accessibility to capture system shortcuts")
    }

    private func setKeyboardCaptureStatus(_ status: String) {
        guard controller?.keyboardCaptureStatus != status else { return }
        controller?.keyboardCaptureStatus = status
    }

    func receiveCapturedKey(_ event: NSEvent) -> Bool {
        guard canCaptureKeyboard else { keyboardCapture.stop(); return false }
        forwardingCapturedKey = true
        defer { forwardingCapturedKey = false }
        switch event.type {
        case .keyDown: keyDown(with: event)
        case .keyUp: keyUp(with: event)
        case .flagsChanged: flagsChanged(with: event)
        default: return false
        }
        return true
    }

    func suspendInput() {
        inputSuspended = true
        releaseFocus()
        window?.makeFirstResponder(nil)
    }

    func resumeInput() {
        inputSuspended = false
        controller?.inputFocused = true
        refreshKeyboardCapture()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isInjectedKey(event) { return true }
        let togglesFullScreen =
            event.keyCode == 3
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .control]
        guard window?.firstResponder === self, controller?.controlActive == true || togglesFullScreen else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    private func sendMove(_ event: NSEvent) {
        refreshCursor(at: convert(event.locationInWindow, from: nil))
        guard let point = normalizedPoint(event, clamp: !buttonsDown.isEmpty) else { return }
        guard !inputSuspended, windowIsActive(window) else { return }
        controller?.sendPointerMove(x: point.x, y: point.y)
    }

    private func isInjectedKey(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == RemoteDesktopKeyboardCapture.injectedEventTag
    }

    private func sendButton(
        _ button: Dieter_V1_RemoteDesktopPointerButton.Button, down: Bool, event: NSEvent
    ) {
        guard down || buttonsDown.contains(event.buttonNumber), let point = normalizedPoint(event, clamp: !down) else {
            return
        }
        guard !inputSuspended else { return }
        if down { buttonsDown.insert(event.buttonNumber) } else { buttonsDown.remove(event.buttonNumber) }
        controller?.sendPointerButton(
            button, down: down, clickCount: event.clickCount, x: point.x, y: point.y,
            modifiers: event.modifierFlags)
    }

    private func normalizedPoint(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        return RemoteDesktopInputGeometry.normalized(point: point, content: videoContentRect, clamp: clamp)
    }

    private func button(_ number: Int) -> Dieter_V1_RemoteDesktopPointerButton.Button {
        switch number {
        case 2: .middle
        case 3: .back
        case 4: .forward
        default: .middle
        }
    }

    private func modifierIsDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 54, 55: flags.contains(.command)
        case 56, 60: flags.contains(.shift)
        case 57: flags.contains(.capsLock)
        case 58, 61: flags.contains(.option)
        case 59, 62: flags.contains(.control)
        case 63: flags.contains(.function)
        default: false
        }
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        controller?.sendText(text); unmarkText()
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        markedSelection = selectedRange
    }
    func unmarkText() {
        markedText = NSAttributedString(string: ""); markedSelection = NSRange(location: NSNotFound, length: 0)
    }
    func selectedRange() -> NSRange { markedSelection }
    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= markedText.length else { return nil }
        actualRange?.pointee = range; return markedText.attributedSubstring(from: range)
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = markedRange()
        return window?.convertToScreen(convert(NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 20), to: nil))
            ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {
        // Commands produced by the local input method (arrows, delete, return).
        let keys: [String: UInt16] = [
            "insertNewline:": 36, "insertTab:": 48, "deleteBackward:": 51, "deleteForward:": 117,
            "moveLeft:": 123, "moveRight:": 124, "moveDown:": 125, "moveUp:": 126, "cancelOperation:": 53,
        ]
        if let code = keys[NSStringFromSelector(selector)] {
            controller?.sendKey(code: code, down: true, repeat: false, modifiers: [])
            controller?.sendKey(code: code, down: false, repeat: false, modifiers: [])
        }
    }

}

enum RemoteDesktopInputGeometry {
    static func normalized(point: CGPoint, bounds: CGRect, videoSize: CGSize, clamp: Bool = false) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, videoSize.width > 0, videoSize.height > 0 else {
            return nil
        }
        let content = contentRect(bounds: bounds, videoSize: videoSize)
        return normalized(point: point, content: content, clamp: clamp)
    }
    static func normalized(point: CGPoint, content: CGRect, clamp: Bool = false) -> CGPoint? {
        guard content.width > 0, content.height > 0 else { return nil }
        guard clamp || content.contains(point) else { return nil }
        return CGPoint(
            x: max(0, min(1, (point.x - content.minX) / content.width)),
            y: max(0, min(1, 1 - (point.y - content.minY) / content.height)))
    }
    static func contentRect(bounds: CGRect, videoSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

private final class RemoteDesktopFocusObservers {
    var tokens: [NSObjectProtocol] = []
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

// No global NSCursor.hide/unhide stack: transparent cursor rectangles are scoped
// to the video and AppKit restores the normal pointer on chrome/window changes.
enum RemoteDesktopCursorPresentation: Equatable {
    case local, remote, embedded
    static func resolve(controlling: Bool, active: Bool, inside: Bool, embedded: Bool, remoteVisible: Bool) -> Self {
        if embedded { return .embedded }
        if controlling && active && inside { return .local }
        return remoteVisible ? .remote : .local
    }
}
