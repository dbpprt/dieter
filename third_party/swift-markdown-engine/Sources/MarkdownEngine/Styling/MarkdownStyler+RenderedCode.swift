// Dieter extension: opt-in diagrams without replacing the Markdown text storage.
import AppKit

extension MarkdownStyler {
    static func styleRenderedCodeBlocks(_ ctx: StylingContext) -> [StyledRange] {
        guard !ctx.configuration.rawSourceMode else { return [] }
        var attrs: [StyledRange] = []
        let width = effectiveContainerWidth(for: ctx)
        for (index, token) in ctx.scoped(ctx.renderedCodeIndexed) {
            guard !ctx.activeTokenIndices.contains(index), token.contentRange.length > 0,
                let paragraphRange = token.standaloneParagraphRange(in: ctx.nsText),
                let language = MarkdownTokenizer.extractLanguage(from: token, in: ctx.nsText as String)
            else { continue }
            let code = ctx.nsText.substring(with: token.contentRange)
            let leadingWhitespace = code.utf16.prefix { unit in
                UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
            }.count
            guard leadingWhitespace < token.contentRange.length,
                let result = ctx.services.renderedCodeBlocks.render(
                    code: code, language: language, availableWidth: width, theme: ctx.configuration.theme),
                let size = renderedCodeSize(result.size, availableWidth: width)
            else { continue }
            let anchor = NSRange(location: token.contentRange.location + leadingWhitespace, length: 1)
            let anchorParagraph = ctx.nsText.paragraphRange(for: anchor)
            // A single contiguous style covers arbitrarily large JSON. Per-line
            // attributes and measuring the entire hidden source made large reports
            // expensive to open and expensive again after every image completed.
            let lineCount = max(1, code.utf16.reduce(0) { $1 == 10 ? $0 + 1 : $0 })
            let hiddenLineHeight = min(0.01, 1 / CGFloat(lineCount + 2))
            let hiddenParagraph = NSMutableParagraphStyle()
            hiddenParagraph.minimumLineHeight = hiddenLineHeight
            hiddenParagraph.maximumLineHeight = hiddenLineHeight
            hiddenParagraph.lineBreakMode = .byClipping
            let imageParagraph = hiddenParagraph.mutableCopy() as! NSMutableParagraphStyle
            imageParagraph.minimumLineHeight = size.height
            imageParagraph.maximumLineHeight = size.height
            imageParagraph.paragraphSpacingBefore = 8
            imageParagraph.paragraphSpacing = 12
            attrs.append(
                (
                    paragraphRange,
                    [
                        .font: ctx.latexMarkerFont, .foregroundColor: NSColor.clear,
                        .backgroundColor: NSColor.clear, .spellingState: 0,
                        .kern: 0, .paragraphStyle: hiddenParagraph,
                    ]
                ))
            attrs.append((token.range, [.renderedCodeBlockRange: NSValue(range: token.range)]))
            attrs.append((anchorParagraph, [.paragraphStyle: imageParagraph]))
            attrs.append(
                (
                    anchor,
                    [
                        .latexImage: result.image, .latexBounds: NSValue(rect: CGRect(origin: .zero, size: size)),
                        .latexIsBlock: true,
                        .kern: size.width
                            - HeadingHelpers.textWidth(ctx.nsText.substring(with: anchor), font: ctx.latexMarkerFont),
                        .renderedCodeBlockSource: code, .renderedCodeBlockLanguage: language,
                        .scrollableBlockFullRange: NSValue(range: paragraphRange),
                    ]
                ))
        }
        return attrs
    }

    static func renderedCodeSize(_ size: CGSize, availableWidth: CGFloat) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
            availableWidth.isFinite, availableWidth > 0
        else { return nil }
        let scale = min(1, availableWidth / size.width)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
