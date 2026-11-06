//
//  DieterTableInteractionTests.swift
//  MarkdownEngineTests
//
//  Dieter patches: links inside rendered tables are drawn as labels and
//  follow clicks (inline and wide tables), a read-only view never reveals
//  block source, and its table menu copies the table as Markdown or TSV.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Dieter table interaction", .serialized)
struct DieterTableInteractionTests {

    static let narrowTable = """
        Intro paragraph.

        | File | Advisory |
        |---|---|
        | [README](README.md) | [CVE-1](https://example.com/cve) |

        Tail.
        """

    static let wideTable = """
        Intro paragraph.

        | Package | Current | Fixed in | Severity | Advisory | Importers | Notes |
        |:--|--:|--:|:-:|:--|--:|:--|
        | [x/net](docs/net.md) | 0.36.0 | 0.38.0 | critical | [CVE-2026-1182](https://example.com/cve) | 14 | HTTP/2 rapid reset variant with a long note |
        | quic-go | 0.52.1 | 0.54.0 | critical | GHSA-7x2m-aaaa-bbbb | 3 | Used by the WebRTC path and more words |

        Tail.
        """

    @MainActor
    final class Harness {
        let window: NSWindow
        let textView: NativeTextView
        let coordinator: NativeTextViewCoordinator
        var clicked: [URL] = []

        init(source: String, editable: Bool, width: CGFloat = 700) throws {
            _ = NSApplication.shared
            let frame = NSRect(x: 0, y: 0, width: width, height: 600)
            let scrollView = ClampedScrollView(frame: frame)
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.drawsBackground = false

            let textView = NativeTextView(frame: .zero)
            let textContainer = try #require(textView.textContainer)
            let textLayoutManager = try #require(textView.textLayoutManager)
            textContainer.lineFragmentPadding = 0
            textContainer.heightTracksTextView = false
            textContainer.widthTracksTextView = true

            var configuration = MarkdownEditorConfiguration.default
            configuration.textInsets = TextInsets(horizontal: 12, vertical: 10)
            let font = NSFont.systemFont(ofSize: 14)
            let coordinator = NativeTextViewCoordinator(
                text: .constant(source),
                fontName: font.fontName,
                fontSize: font.pointSize,
                isWikiLinkActive: .constant(false),
                onLinkClick: nil,
                onInlineSelectionChange: nil
            )
            coordinator.configuration = configuration
            let layoutDelegate = MarkdownLayoutManagerDelegate()
            coordinator.layoutDelegate = layoutDelegate
            textLayoutManager.delegate = layoutDelegate
            let layoutBridge = LayoutBridge(textLayoutManager)
            coordinator.layoutBridge = layoutBridge

            textView.configuration = configuration
            textView.textContainerInset = NSSize(width: 12, height: 10)
            textView.baseFont = font
            textView.font = font
            textView.isEditable = editable
            textView.isSelectable = true
            textView.isRichText = true
            textView.isVerticallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.layoutBridge = layoutBridge
            textView.string = source
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.delegate = coordinator

            let container = NativeTextViewContainer(frame: frame)
            container.autoresizingMask = [.width]
            container.clipsToBounds = true
            container.textView = textView
            textView.frame = NSRect(x: 0, y: 0, width: frame.width, height: 0)
            container.addSubview(textView)
            scrollView.documentView = container

            let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = scrollView
            window.orderFrontRegardless()

            coordinator.textView = textView
            coordinator.rebuildTextStorageAndStyle(textView, from: source, invalidateLayout: true)
            textView.recalcOverscroll(for: scrollView)
            self.window = window
            self.textView = textView
            self.coordinator = coordinator
            coordinator.onURLClick = { [weak self] url in
                self?.clicked.append(url)
                return true
            }
            Self.drain(0.05)
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
            textView.updateWideTableOverlays(immediately: true)
        }

        func close() { window.orderOut(nil) }

        static func drain(_ duration: TimeInterval) {
            let deadline = Date(timeIntervalSinceNow: duration)
            while Date() < deadline {
                RunLoop.main.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.01)))
            }
        }

        var storage: NSTextStorage { textView.textStorage! }

        /// The table anchor (first `.scrollableBlockFullRange` run) and its image.
        func tableAnchor() -> (location: Int, image: NSImage)? {
            var result: (Int, NSImage)?
            storage.enumerateAttribute(
                .scrollableBlockFullRange, in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                guard value != nil,
                      let image = storage.attribute(.latexImage, at: range.location, effectiveRange: nil) as? NSImage
                else { return }
                result = (range.location, image)
                stop.pointee = true
            }
            return result
        }

        /// The anchor's approximate rect in view coordinates (TextKit's segment).
        func approximateTableRect() throws -> CGRect {
            let anchor = try #require(tableAnchor())
            let container = try #require(textView.textContainer)
            var rect = try #require(textView.layoutBridge).boundingRect(
                forCharacterRange: NSRange(location: anchor.location, length: 1), in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            rect.size = anchor.image.size
            return rect
        }

        func select(_ range: NSRange) {
            textView.setSelectedRange(range)
            coordinator.textViewDidChangeSelection(
                Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
        }

        func mouseDown(in view: NSView, at point: CGPoint, clickCount: Int = 1) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clickCount,
                    pressure: 1))
        }

        func rightMouseDown(in view: NSView, at point: CGPoint) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        }
    }

    // MARK: - (a) Links in cells

    @Test func cellLinksDrawTheirLabelAndKeepTheirDestination() {
        _ = NSApplication.shared
        let cfg = MarkdownEditorConfiguration.default
        let cell = MarkdownStyler.formattedCellString(
            "see [the **README**](README.md) now", baseFont: NSFont.systemFont(ofSize: 14), header: false,
            theme: cfg.theme, codeBackgroundColor: .clear, latex: cfg.services.latex)
        #expect(cell.string == "see the README now")
        #expect(!cell.string.contains("]("))
        let index = (cell.string as NSString).range(of: "README").location
        #expect(cell.attribute(.tableCellLinkDestination, at: index, effectiveRange: nil) as? String == "README.md")
        #expect(cell.attribute(.underlineStyle, at: index, effectiveRange: nil) != nil)
        #expect(cell.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor == cfg.theme.link)
        #expect(cell.attribute(.tableCellLinkDestination, at: 0, effectiveRange: nil) == nil)
    }

    @Test func renderedTablesRecordEveryLinkInsideTheImage() throws {
        let harness = try Harness(source: Self.narrowTable, editable: true)
        defer { harness.close() }
        let image = try #require(harness.tableAnchor()?.image as? RenderedTableImage)
        #expect(image.linkRegions.map(\.destination) == ["README.md", "https://example.com/cve"])
        let bounds = CGRect(origin: .zero, size: image.size)
        for region in image.linkRegions {
            #expect(bounds.contains(region.rect))
            #expect(region.rect.width > 10 && region.rect.height > 8)
        }
        // Both links share the body row, below the header row.
        #expect(image.linkRegions[0].rect.midY == image.linkRegions[1].rect.midY)
        #expect(image.linkRegions[0].rect.minY > image.size.height / 2 - 2)
        #expect(image.linkRegions[0].rect.maxX < image.linkRegions[1].rect.minX)
    }

    @Test func clickingAnInlineTableLinkFollowsItsOriginalDestination() throws {
        for editable in [true, false] {
            let harness = try Harness(source: Self.narrowTable, editable: editable)
            defer { harness.close() }
            let approximate = try harness.approximateTableRect()
            let table = try #require(harness.textView.renderedTable(at: CGPoint(x: approximate.midX, y: approximate.midY)))
            #expect(table.frame.size == table.image.size)
            #expect(abs(table.frame.minX - approximate.minX) < 1)
            #expect(abs(table.frame.minY - approximate.minY) < 20)
            let selection = harness.textView.selectedRange()
            for region in table.image.linkRegions {
                let point = CGPoint(x: table.frame.minX + region.rect.midX, y: table.frame.minY + region.rect.midY)
                // A miss would enter NSTextView's modal mouse tracking: only click a hit.
                guard harness.textView.tableCellLinkDestination(at: point) == region.destination else {
                    Issue.record("no link at \(point) for \(region.destination)")
                    continue
                }
                harness.textView.mouseDown(with: try harness.mouseDown(in: harness.textView, at: point))
            }
            #expect(harness.clicked.map(\.absoluteString) == ["README.md", "https://example.com/cve"])
            // The regions are where the text view actually draws the link labels.
            let bitmap = try #require(harness.textView.bitmapImageRepForCachingDisplay(in: harness.textView.bounds))
            harness.textView.cacheDisplay(in: harness.textView.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / harness.textView.bounds.width
            func bluePixels(in rect: CGRect) -> Int {
                var count = 0
                for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
                    for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
                        guard let color = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?
                            .usingColorSpace(.sRGB) else { continue }
                        if color.blueComponent - color.redComponent > 0.3 { count += 1 }
                    }
                }
                return count
            }
            for region in table.image.linkRegions {
                #expect(bluePixels(in: region.rect.offsetBy(dx: table.frame.minX, dy: table.frame.minY)) > 10)
            }
            #expect(bluePixels(in: CGRect(x: table.frame.minX, y: table.frame.minY, width: table.frame.width, height: 20)) == 0)
            #expect(harness.textView.selectedRange() == selection, "following a link is not caret placement")
            // Between the links nothing is followed.
            #expect(harness.textView.tableCellLinkDestination(
                at: CGPoint(x: table.frame.minX + 4, y: table.frame.minY + 4)) == nil)
        }
    }

    @Test func clickingAWideTableLinkFollowsIt() throws {
        for editable in [true, false] {
            let harness = try Harness(source: Self.wideTable, editable: editable, width: 420)
            defer { harness.close() }
            let overlay = try #require(harness.textView.wideTableOverlays.values.first)
            let imageView = try #require(overlay.documentView as? WideTableImageView)
            let image = try #require(imageView.image as? RenderedTableImage)
            let first = try #require(image.linkRegions.first)
            #expect(first.destination == "docs/net.md")
            let local = CGPoint(
                x: first.rect.midX, y: imageView.isFlipped ? first.rect.midY : imageView.bounds.height - first.rect.midY)
            #expect(imageView.linkDestination(at: local) == "docs/net.md")
            #expect(harness.textView.tableCellLinkDestination(at: imageView.convert(local, to: harness.textView))
                == "docs/net.md")
            let selection = harness.textView.selectedRange()
            imageView.mouseDown(with: try harness.mouseDown(in: imageView, at: local))
            #expect(harness.clicked.map(\.absoluteString) == ["docs/net.md"])
            #expect(harness.textView.selectedRange() == selection)
        }
    }

    // MARK: - (b) Read-only presentation

    static let mixed = """
        ## Summary

        Some **bold** words and a [link](https://example.com) here.

        | A | B |
        |---|---|
        | 1 | 2 |

        Tail.
        """

    @Test func readOnlySelectionNeverRevealsBlockOrInlineSource() throws {
        let harness = try Harness(source: Self.mixed, editable: false)
        defer { harness.close() }
        let ns = Self.mixed as NSString
        let heading = ns.range(of: "## ").location
        let bold = ns.range(of: "**bold**").location
        let urlOpen = ns.range(of: "(https").location
        let cell = ns.range(of: "| 1 |").location + 2
        func hidden() -> Bool {
            let storage = harness.storage
            let headingKern = storage.attribute(.kern, at: heading, effectiveRange: nil) as? CGFloat ?? 0
            let boldKern = storage.attribute(.kern, at: bold, effectiveRange: nil) as? CGFloat ?? 0
            let urlColor = storage.attribute(.foregroundColor, at: urlOpen, effectiveRange: nil) as? NSColor
            return headingKern < 0 && boldKern < 0 && urlColor == .clear && harness.tableAnchor() != nil
        }
        #expect(hidden())
        for location in [heading + 1, bold + 3, urlOpen + 3, cell, ns.range(of: "|---").location] {
            harness.select(NSRange(location: location, length: 0))
            #expect(hidden(), "a caret at \(location) reveals source")
            harness.select(NSRange(location: max(0, location - 2), length: 4))
            #expect(hidden(), "a selection at \(location) reveals source")
        }

        // The same caret in an editable view does reveal the table: the check is real.
        let editable = try Harness(source: Self.mixed, editable: true)
        defer { editable.close() }
        #expect(editable.tableAnchor() != nil)
        editable.select(NSRange(location: cell, length: 0))
        #expect(editable.tableAnchor() == nil)
    }

    @Test func readOnlyWideTableClicksNeverMoveTheCaretIntoTheSource() throws {
        let readOnly = try Harness(source: Self.wideTable, editable: false, width: 420)
        defer { readOnly.close() }
        let overlay = try #require(readOnly.textView.wideTableOverlays.values.first)
        let imageView = try #require(overlay.documentView as? WideTableImageView)
        let corner = CGPoint(x: 3, y: imageView.isFlipped ? 3 : imageView.bounds.height - 3)
        #expect(imageView.linkDestination(at: corner) == nil)
        let before = readOnly.textView.selectedRange()
        imageView.mouseDown(with: try readOnly.mouseDown(in: imageView, at: corner))
        #expect(readOnly.textView.selectedRange() == before)
        #expect(readOnly.textView.wideTableOverlays.count == 1)
        #expect(readOnly.clicked.isEmpty)

        // Editable views keep entering the table's source.
        let editable = try Harness(source: Self.wideTable, editable: true, width: 420)
        defer { editable.close() }
        let editableOverlay = try #require(editable.textView.wideTableOverlays.values.first)
        let editableImage = try #require(editableOverlay.documentView as? WideTableImageView)
        editableImage.mouseDown(with: try editable.mouseDown(in: editableImage, at: corner))
        #expect(editable.textView.selectedRange().location == editableOverlay.anchorTextLocation)
    }

    // MARK: - (c) Copy table menu

    @Test func tsvUsesTheVisibleCellText() {
        let tsv = MarkdownStyler.tableTSV(from: "| A | B |\n|:--|--:|\n| **x** `y` | [l](u) |\n| a\\|b | c<br>d |")
        #expect(tsv == "A\tB\nx y\tl\na|b\tc d")
        #expect(MarkdownStyler.tableTSV(from: "not a table") == nil)
    }

    @Test func readOnlyTableMenusCopyTheTableAsMarkdownAndTSV() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dieter.table-copy.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let tableSource = """
            | File | Advisory |
            |---|---|
            | [README](README.md) | [CVE-1](https://example.com/cve) |
            """
        let readOnly = try Harness(source: Self.narrowTable, editable: false)
        defer { readOnly.close() }
        readOnly.textView.tableCopyPasteboard = pasteboard
        readOnly.coordinator.onBuildContextMenu = { menu, _ in
            menu.addItem(withTitle: "Embedder", action: nil, keyEquivalent: "")
            return menu
        }
        let rect = try readOnly.approximateTableRect()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let event = try readOnly.rightMouseDown(in: readOnly.textView, at: center)
        let menu = try #require(readOnly.coordinator.textView(readOnly.textView, menu: NSMenu(), for: event, at: 0))
        #expect(menu.items.map(\.title).prefix(2) == ["Copy Table as Markdown", "Copy Table as TSV"])
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items.last?.title == "Embedder")

        func invoke(_ item: NSMenuItem) {
            _ = (item.target as AnyObject?)?.perform(item.action, with: item)
        }
        invoke(menu.items[0])
        #expect(pasteboard.string(forType: .string) == tableSource)
        invoke(menu.items[1])
        #expect(pasteboard.string(forType: .string) == "File\tAdvisory\nREADME\tCVE-1")
        #expect(pasteboard.string(forType: .tabularText) == "File\tAdvisory\nREADME\tCVE-1")

        // Outside the table, and in editable views, the menu stays the embedder's.
        let outside = try readOnly.rightMouseDown(in: readOnly.textView, at: CGPoint(x: rect.midX, y: 4))
        let plain = try #require(readOnly.coordinator.textView(readOnly.textView, menu: NSMenu(), for: outside, at: 0))
        #expect(plain.items.map(\.title) == ["Embedder"])
        let editable = try Harness(source: Self.narrowTable, editable: true)
        defer { editable.close() }
        let editableRect = try editable.approximateTableRect()
        let editableEvent = try editable.rightMouseDown(
            in: editable.textView, at: CGPoint(x: editableRect.midX, y: editableRect.midY))
        let editableMenu = try #require(
            editable.coordinator.textView(editable.textView, menu: NSMenu(), for: editableEvent, at: 0))
        #expect(!editableMenu.items.contains { $0.title.hasPrefix("Copy Table") })
    }

    @Test func readOnlyWideTablesOfferTheSameMenu() throws {
        let readOnly = try Harness(source: Self.wideTable, editable: false, width: 420)
        defer { readOnly.close() }
        let overlay = try #require(readOnly.textView.wideTableOverlays.values.first)
        let imageView = try #require(overlay.documentView as? WideTableImageView)
        let event = try readOnly.rightMouseDown(in: imageView, at: CGPoint(x: 5, y: 5))
        let menu = try #require(imageView.menu(for: event))
        #expect(menu.items.map(\.title) == ["Copy Table as Markdown", "Copy Table as TSV"])

        let editable = try Harness(source: Self.wideTable, editable: true, width: 420)
        defer { editable.close() }
        let editableImage = try #require(editable.textView.wideTableOverlays.values.first?.documentView as? WideTableImageView)
        let editableMenu = editableImage.menu(for: try editable.rightMouseDown(in: editableImage, at: CGPoint(x: 5, y: 5)))
        #expect(editableMenu?.items.contains { $0.title.hasPrefix("Copy Table") } != true)
    }
}
