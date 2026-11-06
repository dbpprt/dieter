// Dieter extension: links inside rendered tables, and the read-only table
// copy menu. Rendered tables are images, so neither their links nor their
// text can be reached through the text storage.
import AppKit

extension NativeTextView {

    /// The table drawn inline (not through a wide-table overlay) under
    /// `viewPoint`: its anchor, image, and the image's frame in view coordinates.
    func renderedTable(at viewPoint: CGPoint) -> (anchor: Int, image: RenderedTableImage, frame: CGRect)? {
        guard let tlm = textLayoutManager else { return nil }
        let origin = textContainerOrigin
        let containerPoint = CGPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
        guard let fragment = tlm.textLayoutFragment(for: containerPoint) as? MarkdownTextLayoutFragment,
              let hit = fragment.renderedTable(at: containerPoint) else { return nil }
        return (hit.anchor, hit.image, hit.frame.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// The destination of the table-cell link under `viewPoint`, in an inline
    /// table or a wide-table overlay.
    func tableCellLinkDestination(at viewPoint: CGPoint) -> String? {
        if let table = renderedTable(at: viewPoint) {
            return table.image.linkDestination(
                at: CGPoint(x: viewPoint.x - table.frame.minX, y: viewPoint.y - table.frame.minY))
        }
        for (_, overlay) in wideTableOverlays where overlay.superview != nil && !overlay.isHidden {
            if let destination = overlay.linkDestination(at: viewPoint, from: self) { return destination }
        }
        return nil
    }

    /// A plain click on an inline table's cell link follows it.
    func followTableCellLinkIfHit(event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard event.clickCount == 1, !event.modifierFlags.contains(.shift),
              let coordinator = delegate as? NativeTextViewCoordinator,
              let table = renderedTable(at: point),
              let destination = table.image.linkDestination(
                at: CGPoint(x: point.x - table.frame.minX, y: point.y - table.frame.minY))
        else { return false }
        coordinator.openTableCellLink(destination)
        return true
    }

    /// The Markdown source of the table anchored at `anchor`.
    func tableSource(anchor: Int) -> String? {
        guard let storage = textStorage, anchor >= 0, anchor < storage.length,
              let value = storage.attribute(.scrollableBlockFullRange, at: anchor, effectiveRange: nil) as? NSValue
        else { return nil }
        let range = value.rangeValue
        guard range.location != NSNotFound, NSMaxRange(range) <= storage.length else { return nil }
        let source = (storage.string as NSString).substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? nil : source
    }

    /// Read-only views: puts "Copy Table as Markdown" and "Copy Table as TSV"
    /// for the table anchored at `anchor` at the top of `menu`.
    func prependTableCopyItems(to menu: NSMenu, anchor: Int) {
        guard !isEditable, let source = tableSource(anchor: anchor) else { return }
        let pasteboard = tableCopyPasteboard
        var items: [NSMenuItem] = [
            TableCopyMenuItem(title: "Copy Table as Markdown", identifier: TableCopyMenuItem.markdown) {
                pasteboard.clearContents()
                pasteboard.setString(source, forType: .string)
            }
        ]
        if let tsv = MarkdownStyler.tableTSV(from: source, registry: configuration.extensionRegistry) {
            items.append(TableCopyMenuItem(title: "Copy Table as TSV", identifier: TableCopyMenuItem.tsv) {
                pasteboard.clearContents()
                pasteboard.setString(tsv, forType: .string)
                pasteboard.setString(tsv, forType: .tabularText)
            })
        }
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for item in items.reversed() { menu.insertItem(item, at: 0) }
    }
}

extension NativeTextViewCoordinator {
    /// A link drawn inside a rendered table goes where a body link goes: to
    /// the embedder's URL handler (unless ⌘ is held), else, when it names a
    /// scheme, to the system.
    func openTableCellLink(_ destination: String) {
        guard let url = URL(string: destination) else { return }
        let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if !commandHeld, MainActor.assumeIsolated({ onURLClick?(url) == true }) { return }
        if url.scheme != nil { NSWorkspace.shared.open(url) }
    }
}

/// A context-menu item that runs a closure.
final class TableCopyMenuItem: NSMenuItem {
    static let markdown = "markdownEngine.copyTableMarkdown"
    static let tsv = "markdownEngine.copyTableTSV"

    private let handler: () -> Void

    init(title: String, identifier: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func invoke() { handler() }
}
