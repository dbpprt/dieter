import AppKit
import SwiftUI

/// A native multiline editor so attachment paste is handled by the actual
/// first responder. SwiftUI's paste command does not run when its TextField's
/// AppKit field editor consumes Paste first.
struct QuickTaskStoryEditor: NSViewRepresentable {
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let canPasteAttachment: (NSPasteboard) -> Bool
    let pasteAttachment: (NSPasteboard) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> QuickTaskStoryEditorContainer {
        let view = QuickTaskStoryEditorContainer()
        view.textView.delegate = context.coordinator
        view.textView.canPasteAttachment = canPasteAttachment
        view.textView.pasteAttachment = pasteAttachment
        context.coordinator.apply(text, to: view.textView)
        return view
    }

    func updateNSView(_ view: QuickTaskStoryEditorContainer, context: Context) {
        context.coordinator.parent = self
        view.textView.canPasteAttachment = canPasteAttachment
        view.textView.pasteAttachment = pasteAttachment
        if view.textView.string != text {
            context.coordinator.apply(text, to: view.textView)
        }
        updateFocus(of: view.textView)
        view.needsLayout = true
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: QuickTaskStoryEditorContainer,
        context: Context
    ) -> CGSize? {
        let proposedWidth = proposal.width ?? nsView.bounds.width
        guard proposedWidth.isFinite, proposedWidth > 0 else { return nil }
        return CGSize(width: proposedWidth, height: nsView.fittingHeight(for: proposedWidth))
    }

    static func dismantleNSView(_ view: QuickTaskStoryEditorContainer, coordinator: Coordinator) {
        view.textView.delegate = nil
        view.textView.canPasteAttachment = nil
        view.textView.pasteAttachment = nil
    }

    private func updateFocus(of textView: NSTextView) {
        if focus.wrappedValue {
            guard textView.window?.firstResponder !== textView else { return }
            DispatchQueue.main.async { [weak textView] in
                guard focus.wrappedValue, let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        } else if textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QuickTaskStoryEditor
        private var applyingUpdate = false

        init(parent: QuickTaskStoryEditor) { self.parent = parent }

        func apply(_ text: String, to textView: QuickTaskStoryTextView) {
            applyingUpdate = true
            let selection = textView.selectedRange()
            textView.string = text
            textView.applyBaseAttributes()
            textView.setSelectedRange(
                NSIntersectionRange(selection, NSRange(location: 0, length: (text as NSString).length)))
            applyingUpdate = false
        }

        func textDidChange(_ notification: Notification) {
            guard !applyingUpdate, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.focus.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.focus.wrappedValue = false
        }
    }
}

@MainActor
final class QuickTaskStoryEditorContainer: NSScrollView {
    let textView = QuickTaskStoryTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .noBorder
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = true
        autohidesScrollers = true

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: max(1, frameRect.width), height: .greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.applyBaseAttributes()
        documentView = textView
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let viewport = contentSize
        guard viewport.width > 0, let textContainer = textView.textContainer,
            let layoutManager = textView.layoutManager
        else { return }
        let containerSize = NSSize(width: viewport.width, height: .greatestFiniteMagnitude)
        if textContainer.containerSize != containerSize { textContainer.containerSize = containerSize }
        layoutManager.ensureLayout(for: textContainer)
        let documentHeight = max(viewport.height, ceil(layoutManager.usedRect(for: textContainer).height))
        textView.frame = NSRect(x: 0, y: 0, width: viewport.width, height: documentHeight)
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        guard let textContainer = textView.textContainer, let layoutManager = textView.layoutManager else { return 72 }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 13))
        let contentHeight = layoutManager.usedRect(for: textContainer).height
        return ceil(min(max(contentHeight, lineHeight * 4), lineHeight * 7))
    }
}

@MainActor
final class QuickTaskStoryTextView: NSTextView, AttachmentPasteFirstResponder {
    var canPasteAttachment: ((NSPasteboard) -> Bool)?
    var pasteAttachment: ((NSPasteboard) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if consumesAttachmentPasteShortcut(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        consumesAttachmentPasteShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), canPasteAttachment?(.general) == true {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        if consumesAttachmentPaste(from: .general) { return }
        super.paste(sender)
    }

    func consumesAttachmentPaste(from pasteboard: NSPasteboard) -> Bool {
        pasteAttachment?(pasteboard) == true
    }

    private func consumesAttachmentPasteShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
            event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "v"
        else { return false }
        return consumesAttachmentPaste(from: .general)
    }

    func applyBaseAttributes() {
        let font = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        self.font = font
        textColor = .labelColor
        defaultParagraphStyle = paragraph
        typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        if let textStorage, textStorage.length > 0 {
            textStorage.addAttributes(typingAttributes, range: NSRange(location: 0, length: textStorage.length))
        }
    }
}
