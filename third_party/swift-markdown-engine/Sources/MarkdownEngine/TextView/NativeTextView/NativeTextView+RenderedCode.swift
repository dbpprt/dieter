// Dieter extension: native diagram hit testing and keyboard source editing.
import AppKit

extension NativeTextView {
    /// Hit the image before AppKit tries to place a caret in its collapsed text.
    /// This deliberately does not run a modal mouse tracking loop.
    func revealRenderedCodeIfHit(event: NSEvent) -> Bool {
        guard isEditable, event.clickCount == 1,
              !event.modifierFlags.contains(.shift),
              let storage = textStorage, let container = textContainer,
              let coordinator = delegate as? NativeTextViewCoordinator,
              let bridge = coordinator.layoutBridge else { return false }
        let point = convert(event.locationInWindow, from: nil)
        var clickedRange: NSRange?
        storage.enumerateAttribute(.latexImage, in: NSRange(location: 0, length: storage.length)) { image, anchor, stop in
            guard image is NSImage,
                  let source = storage.attribute(.renderedCodeBlockRange, at: anchor.location, effectiveRange: nil) as? NSValue,
                  let size = storage.attribute(.latexBounds, at: anchor.location, effectiveRange: nil) as? NSValue else { return }
            var rect = bridge.boundingRect(forCharacterRange: anchor, in: container)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            rect.size.width = max(rect.width, size.rectValue.width)
            rect.size.height = max(rect.height, size.rectValue.height)
            if rect.contains(point) { clickedRange = source.rangeValue; stop.pointee = true }
        }
        guard let clickedRange else { return false }
        window?.makeFirstResponder(self)
        coordinator.beginNativeInteraction()
        let firstLine = (string as NSString).lineRange(for: NSRange(location: clickedRange.location, length: 0))
        setSelectedRange(NSRange(location: min(NSMaxRange(firstLine), NSMaxRange(clickedRange)), length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: self))
        scrollRangeToVisible(selectedRange())
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isEditable, let coordinator = delegate as? NativeTextViewCoordinator {
            let wasInitial = !coordinator.hasInteractedWithDocument
            coordinator.beginNativeInteraction()
            if wasInitial {
                coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: self))
            }
        }
        super.keyDown(with: event)
    }
}
