import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import DieterMacKit

@MainActor
private func terminalMouseEvent(
    _ type: NSEvent.EventType,
    at point: NSPoint,
    modifiers: NSEvent.ModifierFlags = [],
    in view: NSView
) -> NSEvent {
    NSEvent.mouseEvent(
        with: type,
        location: view.convert(point, to: nil),
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    )!
}

@MainActor
private func terminalKeyEvent(
    _ characters: String,
    modifiers: NSEvent.ModifierFlags,
    in window: NSWindow
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    )!
}

/// The terminal screen reducer and the native SwiftTerm view: palette, caret, geometry, selection, and keys.
struct TerminalsTests {
    @Test func terminalScreenReducerReplaysResetsAndBoundsReconnectState() {
        let first = TerminalScreenReducer.applying(
            data: Data("first".utf8),
            screenReset: true,
            to: TerminalScreenState(),
            limit: 8
        )
        #expect(String(decoding: first.data, as: UTF8.self) == "first")
        #expect(first.resetRevision == 1)

        let appended = TerminalScreenReducer.applying(
            data: Data("-second".utf8),
            screenReset: false,
            to: first,
            limit: 8
        )
        #expect(String(decoding: appended.data, as: UTF8.self) == "t-second")
        #expect(appended.resetRevision == 2)
        #expect(appended.revision == 2)

        let replayed = TerminalScreenReducer.applying(
            data: Data("fresh".utf8),
            screenReset: true,
            to: appended,
            limit: 8
        )
        #expect(String(decoding: replayed.data, as: UTF8.self) == "fresh")
        #expect(replayed.resetRevision == 3)
    }

    @Test func terminalScreenReducerRetainsBoundedChunksWithoutFlatteningEveryAppend() {
        var screen = TerminalScreenState()
        let segment = Data(repeating: 0x61, count: 48 * 1_024)
        for _ in 0..<6 { screen.append(segment, limit: 192 * 1_024) }

        #expect(screen.byteCount == 192 * 1_024)
        #expect(screen.chunks.count >= 3)
        #expect(screen.chunks.allSatisfy { !$0.isEmpty && $0.count <= 64 * 1_024 })
        #expect(screen.data.count == screen.byteCount)
    }

    @Test @MainActor func remoteTerminalPaletteAssignmentsAreIdempotent() {
        let view = RemoteTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let foreground = NSColor.systemGreen
        let background = NSColor.black
        let caret = NSColor.white
        view.applyPalette(foreground: foreground, background: background, caret: caret)
        let mutations = view.paletteMutationCount
        view.applyPalette(foreground: foreground, background: background, caret: caret)
        #expect(view.paletteMutationCount == mutations)

        view.applyPalette(foreground: .systemYellow, background: background, caret: caret)
        #expect(view.paletteMutationCount == mutations + 1)
    }

    @Test @MainActor func remoteTerminalRendererMovesTheVisibleCaretWithOutputAndReplayResets() async throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = SwiftTerm.TerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: font
        )
        // Unit tests do not run an application visibility lifecycle.
        view.suspendsRenderingWhenNotVisible = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let renderer = RemoteTerminalScreenRenderer()

        var screen = TerminalScreenState()
        screen.data = Data("abc".utf8)
        screen.revision = 1
        renderer.apply(screen, to: view)
        try await Task.sleep(nanoseconds: 50_000_000)
        window.display()

        #expect(view.terminalStateSnapshot().cursor.col == 3)
        #expect(view.terminalStateSnapshot().cursor.row == 0)
        #expect(view.caretFrame.origin.x > 0)
        let firstCaret = view.caretFrame

        screen.data.append(Data("\u{001B}[2D".utf8))
        screen.revision += 1
        renderer.apply(screen, to: view)
        try await Task.sleep(nanoseconds: 50_000_000)
        window.display()

        #expect(view.terminalStateSnapshot().cursor.col == 1)
        #expect(view.caretFrame.origin.x < firstCaret.origin.x)

        screen.data.append(Data("\r\nnext".utf8))
        screen.revision += 1
        renderer.apply(screen, to: view)
        try await Task.sleep(nanoseconds: 50_000_000)
        window.display()

        #expect(view.terminalStateSnapshot().cursor.col == 4)
        #expect(view.terminalStateSnapshot().cursor.row == 1)
        #expect(view.caretFrame.origin.y < firstCaret.origin.y)

        screen.data = Data("reset".utf8)
        screen.revision += 1
        screen.resetRevision += 1
        renderer.apply(screen, to: view)
        try await Task.sleep(nanoseconds: 50_000_000)
        window.display()

        #expect(view.terminalStateSnapshot().cursor.col == 5)
        #expect(view.terminalStateSnapshot().cursor.row == 0)
        #expect(view.caretFrame.origin.y == firstCaret.origin.y)
    }

    @Test @MainActor func remoteTerminalViewUsesPersistedGeometryBeforeReconnectReplay() async throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = RemoteTerminalView(frame: .zero, font: font)
        view.prepareForReplay(columns: 120, rows: 36)

        let renderer = RemoteTerminalScreenRenderer()
        var screen = TerminalScreenState()
        screen.data = Data("persisted prompt stays on one row".utf8)
        screen.revision = 1
        renderer.apply(screen, to: view)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(view.terminalDimensions.cols == 120)
        #expect(view.terminalDimensions.rows == 36)
        #expect(view.terminalStateSnapshot().cursor.col == 33)
        #expect(view.terminalStateSnapshot().cursor.row == 0)
    }

    @Test @MainActor func remoteTerminalViewTracksSetFrameSizeGeometry() async throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = RemoteTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 500),
            font: font
        )
        view.prepareForReplay(columns: 120, rows: 36)
        view.feed(text: "terminal resize remains coherent")

        view.setFrameSize(NSSize(width: 520, height: 260))
        try await Task.sleep(nanoseconds: 50_000_000)

        let narrowColumns = view.terminalDimensions.cols
        let narrowRows = view.terminalDimensions.rows
        #expect(narrowColumns > 2 && narrowColumns < 120)
        #expect(narrowRows > 1 && narrowRows < 36)
        #expect(view.terminalStateSnapshot().cursor.col == 32)
        #expect(view.terminalStateSnapshot().cursor.col < narrowColumns)

        view.setFrameSize(NSSize(width: 1_100, height: 620))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(view.terminalDimensions.cols > narrowColumns)
        #expect(view.terminalDimensions.rows > narrowRows)
        #expect(view.terminalStateSnapshot().cursor.col == 32)
        #expect(view.bounds.intersects(view.caretFrame))
    }

    @Test @MainActor func remoteTerminalViewSupportsNativeSelectionCopyPasteAndFocus() async throws {
        let pasteboard = NSPasteboard.general
        let savedPasteboard =
            pasteboard.pasteboardItems?.map { source in
                source.types.compactMap { type in
                    source.data(forType: type).map { (type.rawValue, $0) }
                }
            } ?? []
        defer {
            pasteboard.clearContents()
            let restoredItems = savedPasteboard.map { contents in
                let item = NSPasteboardItem()
                for (type, data) in contents {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                return item
            }
            if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
        }

        let view = RemoteTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.prepareForReplay(columns: 80, rows: 24)
        view.feed(text: "selectable terminal text")
        try await Task.sleep(for: .milliseconds(50))

        _ = window.makeFirstResponder(nil)
        let cell = view.caretFrame.size
        let rowY = view.bounds.height - (cell.height / 2)
        view.mouseDown(with: terminalMouseEvent(.leftMouseDown, at: NSPoint(x: cell.width / 2, y: rowY), in: view))
        view.mouseDragged(
            with: terminalMouseEvent(.leftMouseDragged, at: NSPoint(x: cell.width * 10.5, y: rowY), in: view))
        view.mouseUp(with: terminalMouseEvent(.leftMouseUp, at: NSPoint(x: cell.width * 10.5, y: rowY), in: view))

        #expect(window.firstResponder === view)
        #expect(view.selectedRange().location != NSNotFound)
        #expect(view.selectedRange().length > 0)
        NSApp.sendEvent(terminalKeyEvent("c", modifiers: .command, in: window))
        #expect(pasteboard.string(forType: .string)?.contains("selectable") == true)

        var sent = Data()
        let coordinator = RemoteTerminalSurface.Coordinator(
            terminalID: "clipboard-shell", send: { sent.append($0) }, resize: { _, _ in })
        view.terminalDelegate = coordinator
        pasteboard.clearContents()
        pasteboard.setString("pasted through terminal", forType: .string)
        NSApp.sendEvent(terminalKeyEvent("v", modifiers: .command, in: window))
        // SwiftTerm posts parser-originated paste output to the main queue.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(String(decoding: sent, as: UTF8.self) == "pasted through terminal")

        let menu = view.menu(for: terminalMouseEvent(.rightMouseDown, at: .zero, in: view))
        #expect(menu?.items.map(\.title).filter { !$0.isEmpty } == ["Copy", "Paste", "Select All"])
    }

    @Test @MainActor func remoteTerminalViewEmitsRawTerminalControlBytesForEditingKeys() {
        let view = RemoteTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        var sent = Data()
        let coordinator = RemoteTerminalSurface.Coordinator(
            terminalID: "editing-keys", send: { sent.append($0) }, resize: { _, _ in })
        view.terminalDelegate = coordinator

        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        view.doCommand(by: #selector(NSResponder.moveLeft(_:)))

        #expect(Array(sent) == [0x7f, 0x1b, 0x5b, 0x44])
    }

    @Test @MainActor func remoteTerminalViewUsesShiftDragToSelectWhenApplicationTracksTheMouse() async throws {
        let view = RemoteTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.prepareForReplay(columns: 80, rows: 24)
        view.feed(text: "mouse-aware output\u{001B}[?1000h")
        try await Task.sleep(for: .milliseconds(50))

        let cell = view.caretFrame.size
        let rowY = view.bounds.height - (cell.height / 2)
        let modifiers: NSEvent.ModifierFlags = .shift
        view.mouseDown(
            with: terminalMouseEvent(
                .leftMouseDown, at: NSPoint(x: cell.width / 2, y: rowY), modifiers: modifiers, in: view))
        view.mouseDragged(
            with: terminalMouseEvent(
                .leftMouseDragged, at: NSPoint(x: cell.width * 8.5, y: rowY), modifiers: modifiers, in: view))
        view.mouseUp(
            with: terminalMouseEvent(
                .leftMouseUp, at: NSPoint(x: cell.width * 8.5, y: rowY), modifiers: modifiers, in: view))

        #expect(view.selectedRange().location != NSNotFound)
        #expect(view.selectedRange().length > 0)
    }
}
