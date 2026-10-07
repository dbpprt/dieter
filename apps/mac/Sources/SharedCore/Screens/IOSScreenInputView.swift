#if os(iOS)
    import UIKit
    import Observation
    import DieterShared
    import DieterAPI
    @MainActor package protocol IOSScreenCanvasController: AnyObject {
        var renderer: IOSScreenVideoView { get }
        var touch: SharedTouchScreen { get }
        var sessionState: Dieter_V1_RemoteDesktopSessionState { get }
        var streaming: Bool { get }
        var controlActive: Bool { get }
        var cursor: ScreenCursorState { get }
        var cursorImage: UIImage? { get }
        var hostCursor: CGPoint { get }
        var hostCursorRevision: Int { get }
        var phase: String { get }
        var canvasRevision: Int { get }
        func setViewport(_ size: CGSize, scale: CGFloat)
        func canvasChanged()
    }
    package final class IOSScreenInputView: UIView, UIKeyInput {
        private let controller: any IOSScreenCanvasController
        private let cursorView = UIImageView(frame: .zero)
        private lazy var noKeyboard = UIView(frame: .zero)
        private var fingers: [ObjectIdentifier: Int32] = [:]
        /// Mouse and trackpad clicks held down, by the button each pressed.
        private var pointerButtons: [ObjectIdentifier: Dieter_V1_RemoteDesktopPointerButton.Button] = [:]
        private var nextFinger: Int32 = 0
        private var longPress: Task<Void, Never>?
        private var softwareKeyboard = false
        private var released = false
        private var canvasSize = CGSize.zero
        private var remoteSize = CGSize.zero
        package var keyboardChanged: (Bool) -> Void = { _ in }

        private var touch: SharedTouchScreen { controller.touch }

        package init(controller: any IOSScreenCanvasController) {
            self.controller = controller
            super.init(frame: .zero)
            backgroundColor = .black
            clipsToBounds = true
            isMultipleTouchEnabled = true
            addSubview(controller.renderer)
            cursorView.contentMode = .scaleToFill
            cursorView.isUserInteractionEnabled = false
            cursorView.isHidden = true
            addSubview(cursorView)
            controller.renderer.onVideoSize = { [weak self] _ in self?.setNeedsLayout() }
            isAccessibilityElement = true
            accessibilityLabel = "Remote screen"
            accessibilityHint =
                "One finger moves the pointer and a tap clicks. Hold, then move, to drag. "
                + "Two fingers zoom and pan. Three fingers scroll."
            accessibilityTraits = .allowsDirectInteraction
            installPointerGestures()
            observeController()
        }

        package required init?(coder: NSCoder) { nil }

        /// The view went away: held input is released and the renderer stays
        /// with the controller.
        package func release() {
            guard !released else { return }
            released = true
            longPress?.cancel()
            if !fingers.isEmpty || !pointerButtons.isEmpty { touch.touchesCancelled() }
            fingers = [:]
            pointerButtons = [:]
            if controller.renderer.superview === self { controller.renderer.removeFromSuperview() }
            controller.renderer.onVideoSize = nil
            _ = resignFirstResponder()
        }

        // MARK: Layout

        package override func layoutSubviews() {
            super.layoutSubviews()
            controller.setViewport(bounds.size, scale: window?.screen.scale ?? traitCollection.displayScale)
            applyCanvas()
        }

        /// Places the video and cursor where the shared canvas says.
        private func applyCanvas() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let remote = currentRemoteSize
            if bounds.size != canvasSize || remote != remoteSize {
                canvasSize = bounds.size
                remoteSize = remote
                touch.resize(
                    viewWidth: bounds.width, viewHeight: bounds.height, remoteWidth: remote.width,
                    remoteHeight: remote.height)
            }
            let zoom = max(touch.zoom, 0.01)
            let renderer = controller.renderer
            renderer.transform = .identity
            renderer.bounds = CGRect(x: 0, y: 0, width: touch.contentWidth / zoom, height: touch.contentHeight / zoom)
            renderer.center = CGPoint(
                x: touch.contentX + touch.contentWidth / 2, y: touch.contentY + touch.contentHeight / 2)
            renderer.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            layoutCursor()
            controller.canvasChanged()
        }

        /// The decoded picture's size, else the stream's, else 16:9.
        private var currentRemoteSize: CGSize {
            let video = controller.renderer.videoSize
            if video.width > 0, video.height > 0 { return video }
            let state = controller.sessionState
            if state.width > 0, state.height > 0 { return CGSize(width: Int(state.width), height: Int(state.height)) }
            return CGSize(width: 1920, height: 1080)
        }

        private func layoutCursor() {
            guard controller.streaming, !controller.sessionState.embeddedCursor else {
                cursorView.isHidden = true
                return
            }
            let x = touch.cursorViewX
            let y = touch.cursorViewY
            let cursor = controller.cursor
            if cursor.visible, let image = controller.cursorImage, cursor.width > 0, cursor.height > 0 {
                // Legible on a phone, and at least the desktop's own size when zoomed in.
                let scale = max(1, touch.contentWidth / max(1, remoteSize.width))
                cursorView.image = image
                cursorView.layer.shadowOpacity = 0
                cursorView.frame = CGRect(
                    x: x - cursor.hotspotX * scale, y: y - cursor.hotspotY * scale, width: cursor.width * scale,
                    height: cursor.height * scale)
            } else {
                cursorView.image = Self.arrow
                cursorView.layer.shadowColor = UIColor.black.cgColor
                cursorView.layer.shadowOpacity = 0.8
                cursorView.layer.shadowRadius = 1
                cursorView.layer.shadowOffset = .zero
                cursorView.frame = CGRect(x: x - 4, y: y - 2, width: 18, height: 22)
            }
            cursorView.isHidden = false
        }

        private static let arrow = UIImage(systemName: "cursorarrow")?
            .withTintColor(.white, renderingMode: .alwaysOriginal)

        /// Re-applies the host cursor, control, and canvas whenever the
        /// controller's slice changes them.
        private func observeController() {
            guard !released else { return }
            withObservationTracking {
                _ = controller.hostCursorRevision
                _ = controller.cursor
                _ = controller.cursorImage
                _ = controller.controlActive
                _ = controller.phase
                _ = controller.canvasRevision
                _ = controller.sessionState
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.controllerChanged()
                        self?.observeController()
                    }
                }
            }
        }

        private func controllerChanged() {
            guard !released else { return }
            // A finger holding the cursor wins over the host's position.
            if !touch.holdingCursor {
                touch.setCursor(x: controller.hostCursor.x, y: controller.hostCursor.y)
            }
            if !controller.controlActive {
                longPress?.cancel()
                if softwareKeyboard { keyboardChanged(false) }
            }
            setNeedsLayout()
        }

        // MARK: Touches

        package override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if controller.controlActive, !isFirstResponder { _ = becomeFirstResponder() }
            let touches = pointerTouches(touches) { pointerDown($0, event: event) }
            guard !touches.isEmpty else { return }
            let first = fingers.isEmpty
            for touch in touches {
                let id = nextFinger
                nextFinger &+= 1
                fingers[ObjectIdentifier(touch)] = id
                let point = touch.location(in: self)
                self.touch.touchDown(id: id, x: point.x, y: point.y, canControl: controller.controlActive)
            }
            if first, fingers.count == 1 { scheduleLongPress() } else { longPress?.cancel() }
            applyCanvas()
        }

        package override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = pointerTouches(touches) { pointerMoved($0) }
            guard !touches.isEmpty else { return }
            for touch in touches {
                guard let id = fingers[ObjectIdentifier(touch)] else { continue }
                let point = touch.location(in: self)
                self.touch.touchMoved(id: id, x: point.x, y: point.y)
            }
            if !touch.canLongPress { longPress?.cancel() }
            applyCanvas()
        }

        package override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = pointerTouches(touches) { pointerUp($0) }
            guard !touches.isEmpty else { return }
            for touch in touches {
                guard let id = fingers.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
                let point = touch.location(in: self)
                self.touch.touchUp(id: id, x: point.x, y: point.y, atMillis: Int64(touch.timestamp * 1_000))
            }
            longPress?.cancel()
            applyCanvas()
        }

        package override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = pointerTouches(touches) { pointerUp($0) }
            guard !touches.isEmpty else { return }
            for touch in touches { fingers.removeValue(forKey: ObjectIdentifier(touch)) }
            longPress?.cancel()
            touch.touchesCancelled()
            fingers = [:]
            applyCanvas()
        }

        // MARK: Mouse and trackpad clicks

        /// Handles the clicks of a mouse or trackpad (indirect pointer
        /// touches) with `handle` and returns the fingers.
        private func pointerTouches(_ touches: Set<UITouch>, handle: (UITouch) -> Void) -> Set<UITouch> {
            var fingers = Set<UITouch>()
            for touch in touches {
                if touch.type == .indirectPointer { handle(touch) } else { fingers.insert(touch) }
            }
            return fingers
        }

        /// A click on the desktop presses its button under the pointer:
        /// the secondary button right-clicks and the third middle-clicks.
        private func pointerDown(_ touch: UITouch, event: UIEvent?) {
            guard controller.controlActive else { return }
            let point = touch.location(in: self)
            guard self.touch.pointAt(x: point.x, y: point.y, clamp: false) else { return }
            let button = Self.button(event?.buttonMask ?? .primary)
            pointerButtons[ObjectIdentifier(touch)] = button
            self.touch.pointerButton(button: Int32(button.rawValue), down: true, clicks: Self.clicks(touch))
            layoutCursor()
        }

        /// A drag keeps the cursor under the pointer, at the desktop's edge
        /// when it leaves.
        private func pointerMoved(_ touch: UITouch) {
            guard pointerButtons[ObjectIdentifier(touch)] != nil else { return }
            let point = touch.location(in: self)
            if self.touch.pointAt(x: point.x, y: point.y, clamp: true) { layoutCursor() }
        }

        private func pointerUp(_ touch: UITouch) {
            guard let button = pointerButtons.removeValue(forKey: ObjectIdentifier(touch)) else { return }
            self.touch.pointerButton(button: Int32(button.rawValue), down: false, clicks: Self.clicks(touch))
        }

        /// A single, double, or triple click.
        private static func clicks(_ touch: UITouch) -> Int32 { Int32(min(3, max(1, touch.tapCount))) }

        private static func button(_ mask: UIEvent.ButtonMask) -> Dieter_V1_RemoteDesktopPointerButton.Button {
            if mask.contains(.secondary) { return .right }
            if mask.contains(.button(3)) { return .middle }
            return .left
        }

        /// A finger held still starts a drag once the system's long-press
        /// time has passed.
        private func scheduleLongPress() {
            longPress?.cancel()
            longPress = Task { @MainActor [weak self] in
                do { try await DieterTaskSleep.milliseconds(400) } catch { return }
                guard let self, !Task.isCancelled, self.touch.canLongPress, self.touch.longPress() else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }

        // MARK: Pointer and scrolling

        private func installPointerGestures() {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            hover.cancelsTouchesInView = false
            addGestureRecognizer(hover)

            let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
            scroll.allowedScrollTypesMask = .all
            scroll.allowedTouchTypes = []
            scroll.cancelsTouchesInView = false
            addGestureRecognizer(scroll)
        }

        /// A hardware pointer moves the cursor to the point under it.
        @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
            guard controller.controlActive, gesture.state == .began || gesture.state == .changed else { return }
            let point = gesture.location(in: self)
            if touch.pointAt(x: point.x, y: point.y, clamp: false) { layoutCursor() }
        }

        /// A mouse wheel or trackpad scrolls the host.
        @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
            guard controller.controlActive else { return }
            let delta = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            switch gesture.state {
            case .began: touch.scroll(dx: 0, dy: 0, phase: 1, momentum: 0)
            case .changed: touch.scroll(dx: delta.x, dy: delta.y, phase: 2, momentum: 0)
            case .ended, .cancelled, .failed: touch.scroll(dx: 0, dy: 0, phase: 4, momentum: 0)
            default: break
            }
        }

        // MARK: Keyboard

        package override var canBecomeFirstResponder: Bool { !released }

        /// Without the software keyboard the view still takes hardware keys.
        package override var inputView: UIView? { softwareKeyboard ? nil : noKeyboard }

        package var hasText: Bool { false }

        package func insertText(_ text: String) {
            guard controller.controlActive else { return }
            touch.text(text: text)
        }

        package func deleteBackward() {
            guard controller.controlActive else { return }
            touch.press(hid: 42)
        }

        package var autocorrectionType: UITextAutocorrectionType {
            get { .no }
            set {}
        }

        package var autocapitalizationType: UITextAutocapitalizationType {
            get { .none }
            set {}
        }

        package var smartQuotesType: UITextSmartQuotesType {
            get { .no }
            set {}
        }

        package var smartDashesType: UITextSmartDashesType {
            get { .no }
            set {}
        }

        package var spellCheckingType: UITextSpellCheckingType {
            get { .no }
            set {}
        }

        /// Shows or hides the software keyboard as the toolbar asks.
        package func showSoftwareKeyboard(_ shown: Bool) {
            let wanted = shown && controller.controlActive
            guard wanted != softwareKeyboard || (wanted && !isFirstResponder) else { return }
            softwareKeyboard = wanted
            if wanted {
                if isFirstResponder { reloadInputViews() } else { _ = becomeFirstResponder() }
            } else if isFirstResponder {
                reloadInputViews()
            }
        }

        package override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned, softwareKeyboard, !released {
                softwareKeyboard = false
                keyboardChanged(false)
            }
            return resigned
        }

        package override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !sendKeys(presses, down: true) { super.pressesBegan(presses, with: event) }
        }

        package override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !sendKeys(presses, down: false) { super.pressesEnded(presses, with: event) }
        }

        package override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            _ = sendKeys(presses, down: false)
            super.pressesCancelled(presses, with: event)
        }

        /// Sends hardware keys by HID usage; false when none was sent.
        private func sendKeys(_ presses: Set<UIPress>, down: Bool) -> Bool {
            guard controller.controlActive else { return false }
            var sent = false
            for press in presses {
                guard let key = press.key else { continue }
                touch.key(
                    hid: Int32(truncatingIfNeeded: key.keyCode.rawValue), down: down, repeat: false,
                    modifiers: Self.modifiers(key.modifierFlags))
                sent = true
            }
            return sent
        }

        /// The modifier bits of the screen protocol.
        private static func modifiers(_ flags: UIKeyModifierFlags) -> Int32 {
            var bits: Int32 = 0
            if flags.contains(.shift) { bits |= 1 }
            if flags.contains(.control) { bits |= 2 }
            if flags.contains(.alternate) { bits |= 4 }
            if flags.contains(.command) { bits |= 8 }
            if flags.contains(.alphaShift) { bits |= 16 }
            return bits
        }
    }
#endif
