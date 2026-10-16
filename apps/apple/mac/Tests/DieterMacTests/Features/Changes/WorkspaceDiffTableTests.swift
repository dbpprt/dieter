import AppKit
import DieterClientAPI
import DieterPlatform
import SwiftUI
import Testing
@testable import DieterMacKit

@Suite(.serialized)
@MainActor
struct WorkspaceDiffTableTests {
    @Test func diffLinesWrapToThePaneInsteadOfScrollingSideways() async throws {
        let prose = Array(repeating: "Markdown prose wraps at word boundaries", count: 12).joined(separator: " ")
        let unbroken = String(repeating: "x", count: 400)
        let (window, table) = try await hostDiff(
            diffLayout([
                hunk(0, "@@ -1,3 +1,3 @@"),
                line(1, .context, " short", old: 1, new: 1),
                line(2, .addition, "+" + prose, new: 2),
                line(3, .deletion, "-" + unbroken, old: 3),
            ]), width: 520)
        defer { window.close() }

        let scroll = try #require(table.enclosingScrollView)
        #expect(!scroll.hasHorizontalScroller)
        // Rows wrap to what is visible: nothing lies beyond the clip view.
        #expect(table.tableColumns[0].width <= scroll.contentView.bounds.width + 0.5)
        #expect(table.rect(ofRow: 1).height == WorkspaceDiffStyle.row)
        #expect(table.rect(ofRow: 2).height > 3 * WorkspaceDiffStyle.row)
        #expect(table.rect(ofRow: 3).height > 3 * WorkspaceDiffStyle.row)
        for row in 0..<table.numberOfRows {
            let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? WorkspaceDiffCell)
            cell.layoutSubtreeIfNeeded()
            for text in textViews(in: cell) {
                // The row measured its text exactly as the text view lays it out.
                let layout = try #require(text.layoutManager)
                let container = try #require(text.textContainer)
                layout.ensureLayout(for: container)
                #expect(abs(ceil(layout.usedRect(for: container).height) - text.frame.height) < 0.5)
                #expect(text.frame.maxX <= cell.bounds.width)
                #expect(text.frame.maxY <= table.rect(ofRow: row).height)
            }
        }
    }

    @Test func splitRowsTakeTheTallerSide() async throws {
        let prose = Array(repeating: "a long deleted sentence", count: 20).joined(separator: " ")
        let (window, table) = try await hostDiff(
            diffLayout(
                [
                    pair(1, before: (.deletion, "-" + prose, 1), after: (.addition, "+short", 1)),
                    pair(2, before: (.context, " same", 2), after: (.context, " same", 2)),
                ], split: true), width: 640)
        defer { window.close() }

        #expect(table.rect(ofRow: 0).height > 2 * WorkspaceDiffStyle.row)
        #expect(table.rect(ofRow: 1).height == WorkspaceDiffStyle.row)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? WorkspaceDiffCell)
        cell.layoutSubtreeIfNeeded()
        let sides = textViews(in: cell).sorted { $0.frame.minX < $1.frame.minX }
        #expect(sides.count == 2)
        #expect(sides[0].frame.minY == sides[1].frame.minY)
        #expect(sides[0].frame.height > sides[1].frame.height)
        #expect(sides[0].frame.maxX <= sides[1].frame.minX)
        #expect(sides[1].frame.maxX <= cell.bounds.width)
    }

    @Test func foldsExpandInPlaceAndCloseForANewDiff() async throws {
        let foldRow = ClientDiffDisplayRow.with {
            $0.fold = .with {
                $0.id = 10
                $0.count = 3
                $0.lines = (1...3).map { index in
                    .with {
                        $0.row = .with {
                            $0.id = Int32(10 + index); $0.kind = .context; $0.text = " folded \(index)"
                            $0.oldLine = Int32(index); $0.newLine = Int32(index)
                        }
                    }
                }
            }
        }
        let first = diffLayout([hunk(0, "@@ -1,5 +1,5 @@"), foldRow, line(20, .addition, "+new", new: 4)])
        let root = NSHostingView(rootView: diffContent(first))
        root.sizingOptions = []
        let window = diffWindow(root: root, width: 520)
        defer { window.close() }
        await settleDiff(root)
        let table = try #require(diffTable(in: root))
        #expect(table.numberOfRows == 3)

        let fold = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? WorkspaceDiffCell)
        fold.mouseDown(with: try mouseDown(in: window))
        #expect(table.numberOfRows == 6)
        #expect((table.view(atColumn: 0, row: 2, makeIfNecessary: true) as? WorkspaceDiffCell)?.item?.key == .line(11))

        // Another diff starts with its folds closed.
        root.rootView = diffContent(
            first.folding(
                rows: [hunk(0, "@@ -1,6 +1,6 @@"), foldRow, line(21, .addition, "+newer", new: 5)], unchanged: false,
                split: false, more: false, note: ""))
        await settleDiff(root)
        #expect(table.numberOfRows == 3)
    }

    @Test func largeDiffsMeasureEveryRowButBuildOnlyTheVisibleOnes() async throws {
        let prose = Array(repeating: "wrapped paragraph text", count: 30).joined(separator: " ")
        let rows = (0..<6_000).map { index in
            line(
                Int32(index + 1), index.isMultiple(of: 2) ? .addition : .context,
                index.isMultiple(of: 50) ? "+" + prose : "+let value\(index) = \(index)", new: Int32(index + 1))
        }
        let (window, table) = try await hostDiff(diffLayout(rows), width: 700, height: 600)
        defer { window.close() }

        #expect(table.numberOfRows == 6_000)
        #expect(table.bounds.height > 6_000 * WorkspaceDiffStyle.row)
        var built = 0
        table.enumerateAvailableRowViews { _, _ in built += 1 }
        #expect(built < 120)
    }

    @Test func codeWrapsByColumnsAtTheLastSpaceThatFits() {
        #expect(WorkspaceDiffStyle.code.isFixedPitch)
        func lines(_ text: String, _ columns: Int) -> [String] {
            WorkspaceDiffTextMeasure.softWrapped(text, columns: columns)
                .components(separatedBy: WorkspaceDiffTextMeasure.softBreak)
        }
        #expect(lines("let value = 42", 20) == ["let value = 42"])
        #expect(lines("alpha beta gamma delta", 11) == ["alpha beta ", "gamma delta"])
        // Spaces at a break hang on the line they end; a word longer than a line breaks inside.
        #expect(lines("alpha    beta", 7) == ["alpha    ", "beta"])
        #expect(lines("abcdefghijklmnop", 6) == ["abcdef", "ghijkl", "mnop"])
        #expect(lines("    indented code that wraps", 12) == ["    indented ", "code that ", "wraps"])
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let text = (0..<Int.random(in: 1...40, using: &generator))
                .map { _ in String(repeating: "x", count: Int.random(in: 1...14, using: &generator)) }
                .joined(separator: String(repeating: " ", count: Int.random(in: 1...3, using: &generator)))
            let columns = Int.random(in: 4...60, using: &generator)
            let wrapped = lines(text, columns)
            #expect(wrapped.joined() == text)
            for line in wrapped {
                // Only hanging spaces pass the margin.
                let trimmed = line.replacingOccurrences(of: " +$", with: "", options: .regularExpression)
                #expect(trimmed.count <= columns, "\(line) at \(columns)")
            }
        }
    }

    @Test func textViewsLayOutWhatTheRowsMeasured() {
        let words = ["let", "value", "=", "func", "{", "}", "return", "a_long_identifier_name", "//", "x", "Ünïcödé"]
        var generator = SystemRandomNumberGenerator()
        let view = WorkspaceDiffTextView()
        for font in [WorkspaceDiffStyle.code, WorkspaceDiffStyle.hunk, WorkspaceDiffStyle.comment] {
            for _ in 0..<200 {
                let count = Int.random(in: 1...60, using: &generator)
                let text = (0..<count).map { _ in words.randomElement(using: &generator)! }.joined(separator: " ")
                let width = CGFloat.random(in: 60...700, using: &generator).rounded()
                let measured = WorkspaceDiffTextMeasure.shared.height(text, font: font, width: width)
                view.frame = CGRect(x: 0, y: 0, width: width, height: measured)
                view.show(text, font: font, color: .textColor)
                view.wrap(to: width)
                let layout = view.layoutManager!
                layout.ensureLayout(for: view.textContainer!)
                #expect(ceil(layout.usedRect(for: view.textContainer!).height) == measured, "\(text) at \(width)")
                #expect(layout.usedRect(for: view.textContainer!).width <= width + 8, "\(text) at \(width)")
            }
        }
    }

    @Test func copyingWrappedCodeLeavesTheSoftBreaksOut() throws {
        let view = WorkspaceDiffTextView()
        let text = Array(repeating: "wrapped code", count: 20).joined(separator: " ")
        view.frame = CGRect(x: 0, y: 0, width: 160, height: 400)
        view.show(text, font: WorkspaceDiffStyle.code, color: .textColor)
        view.wrap(to: 160)
        #expect(view.string.contains(WorkspaceDiffTextMeasure.softBreak))
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        let pasteboard = NSPasteboard(name: .init("WorkspaceDiffTableTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == text)
    }
}

// MARK: - Fixtures

@MainActor private func diffLayout(_ rows: [ClientDiffDisplayRow], split: Bool = false) -> WorkspaceDiffLayout {
    WorkspaceDiffLayout().folding(rows: rows, unchanged: false, split: split, more: false, note: "")
}

@MainActor private func diffContent(_ layout: WorkspaceDiffLayout) -> WorkspaceDiffContent {
    WorkspaceDiffContent(layout: layout, addComment: { _ in }, loadMore: {})
}

private func line(
    _ id: Int32, _ kind: ClientDiffRow.Kind, _ text: String, old: Int32 = 0, new: Int32 = 0
) -> ClientDiffDisplayRow {
    .with {
        $0.line = .with {
            $0.row = .with {
                $0.id = id; $0.kind = kind; $0.text = text; $0.oldLine = old; $0.newLine = new
            }
        }
    }
}

private func pair(
    _ id: Int32, before: (ClientDiffRow.Kind, String, Int32), after: (ClientDiffRow.Kind, String, Int32)
) -> ClientDiffDisplayRow {
    .with {
        $0.pair = .with {
            $0.id = id
            $0.before = .with {
                $0.id = id; $0.kind = before.0; $0.text = before.1; $0.oldLine = before.2
            }
            $0.after = .with {
                $0.id = id + 1_000; $0.kind = after.0; $0.text = after.1; $0.newLine = after.2
            }
        }
    }
}

private func hunk(_ id: Int32, _ text: String) -> ClientDiffDisplayRow {
    .with {
        $0.hunk = .with {
            $0.id = id; $0.text = text; $0.additions = 1; $0.deletions = 1
        }
    }
}

@MainActor private func hostDiff(
    _ layout: WorkspaceDiffLayout, width: CGFloat, height: CGFloat = 800
) async throws -> (NSWindow, NSTableView) {
    let root = NSHostingView(rootView: diffContent(layout))
    root.sizingOptions = []
    let window = diffWindow(root: root, width: width, height: height)
    await settleDiff(root)
    return (window, try #require(diffTable(in: root)))
}

@MainActor private func diffWindow(root: NSView, width: CGFloat, height: CGFloat = 800) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    window.setContentSize(NSSize(width: width, height: height))
    return window
}

@MainActor private func settleDiff(_ root: NSView) async {
    for _ in 0..<3 {
        root.layoutSubtreeIfNeeded()
        try? await DieterTaskSleep.milliseconds(80)
    }
    root.layoutSubtreeIfNeeded()
}

@MainActor private func diffTable(in view: NSView) -> NSTableView? {
    if let table = view as? WorkspaceDiffTableView { return table }
    for child in view.subviews {
        if let table = diffTable(in: child) { return table }
    }
    return nil
}

@MainActor private func textViews(in cell: NSView) -> [WorkspaceDiffTextView] {
    cell.subviews.compactMap { $0 as? WorkspaceDiffTextView }.filter { !$0.isHidden }
}

@MainActor private func mouseDown(in window: NSWindow) throws -> NSEvent {
    try #require(
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}
