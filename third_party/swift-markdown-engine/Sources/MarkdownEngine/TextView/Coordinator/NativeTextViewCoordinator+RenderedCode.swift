// Dieter extension: an asynchronous chart completion updates only its image
// anchor. It must not re-highlight or restyle the surrounding Markdown document.
import AppKit

extension NativeTextViewCoordinator {
    func refreshRenderedCodeBlocks(in textView: NSTextView) {
        guard !configuration.rawSourceMode, let storage = textView.textStorage, storage.length > 0 else { return }
        let containerWidth = textView.textContainer?.size.width ?? 0
        let width =
            containerWidth.isFinite && containerWidth > 0 && containerWidth < 100_000
            ? containerWidth : max(1, textView.bounds.width - textView.textContainerInset.width * 2)
        var updates: [(anchor: NSRange, image: NSImage, size: CGSize, oldSize: CGSize)] = []
        var sourceFallbacks: [NSRange] = []
        storage.enumerateAttribute(.renderedCodeBlockSource, in: NSRange(location: 0, length: storage.length)) {
            value, anchor, _ in
            guard let code = value as? String,
                let language = storage.attribute(.renderedCodeBlockLanguage, at: anchor.location, effectiveRange: nil)
                    as? String,
                let oldImage = storage.attribute(.latexImage, at: anchor.location, effectiveRange: nil) as? NSImage,
                let bounds = storage.attribute(.latexBounds, at: anchor.location, effectiveRange: nil) as? NSValue
            else { return }
            guard let result = self.configuration.services.renderedCodeBlocks.render(
                code: code, language: language, availableWidth: width, theme: self.configuration.theme)
            else {
                // A failed asynchronous preview can withdraw its placeholder.
                // Reveal just that fence; successful anchors and prose stay put.
                if self.configuration.services.renderedCodeBlocks.shouldRevealSource(code: code, language: language),
                   let fullRange = storage.attribute(.scrollableBlockFullRange, at: anchor.location, effectiveRange: nil) as? NSValue {
                    sourceFallbacks.append(fullRange.rangeValue)
                }
                return
            }
            guard
                let size = MarkdownStyler.renderedCodeSize(result.size, availableWidth: width),
                oldImage !== result.image || bounds.rectValue.size != size
            else { return }
            updates.append((anchor, result.image, size, bounds.rectValue.size))
        }
        guard !updates.isEmpty || !sourceFallbacks.isEmpty else { return }
        for update in updates {
            storage.beginEditing()
            let oldKern = storage.attribute(.kern, at: update.anchor.location, effectiveRange: nil) as? CGFloat ?? 0
            storage.addAttributes(
                [
                    .latexImage: update.image,
                    .latexBounds: NSValue(rect: CGRect(origin: .zero, size: update.size)),
                    .kern: oldKern + update.size.width - update.oldSize.width,
                ], range: update.anchor)
            if update.size.height != update.oldSize.height,
                let paragraph = storage.attribute(.paragraphStyle, at: update.anchor.location, effectiveRange: nil)
                    as? NSParagraphStyle,
                let updated = paragraph.mutableCopy() as? NSMutableParagraphStyle
            {
                updated.minimumLineHeight = update.size.height
                updated.maximumLineHeight = update.size.height
                let paragraphRange = (storage.string as NSString).paragraphRange(for: update.anchor)
                storage.addAttribute(.paragraphStyle, value: updated, range: paragraphRange)
            }
            storage.endEditing()
        }
        if !sourceFallbacks.isEmpty { restyleParagraphs(sourceFallbacks, in: textView) }
        // NSTextStorage invalidates only the edited paragraphs. Invalidating the
        // document range here would lay out thousands of hidden JSON lines again.
        textView.setNeedsDisplay(textView.visibleRect)
        if let native = textView as? NativeTextView {
            native.ensureVisibleLayout()
            // Chart height changes move every later text anchor. Wide tables
            // are separate views, so reconcile their frames in the same turn.
            // Source offsets are unchanged: reuse the existing anchors rather
            // than scanning or restyling the report's hidden JSON paragraphs.
            if !native.wideTableOverlays.isEmpty,
               !sourceFallbacks.isEmpty || updates.contains(where: { $0.size.height != $0.oldSize.height }) {
                native.updateWideTableOverlays(
                    immediately: true,
                    knownWideTableAnchorRanges: native.wideTableOverlays.values.map {
                        NSRange(location: $0.anchorTextLocation, length: 1)
                    }
                )
            }
        }
    }
}
