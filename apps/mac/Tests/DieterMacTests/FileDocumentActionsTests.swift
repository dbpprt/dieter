import AppKit
import DieterAPI
import DieterCore
import Observation
import SwiftUI
import Testing
@testable import DieterMac

@Test(arguments: ["notes.md", "main.swift", "image.png", "report.pdf", "data.bin"])
@MainActor func documentToolbarShowsFinderAndRevalidatesItsRevealAction(filename: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(filename)
    try Data("# Document".utf8).write(to: file)
    let model = FilesModel()
    model.bind(target: WorkspaceTarget(endpointID: "local", projectID: "project"), client: nil)
    model.selectedFilePath = filename
    var document = Dieter_V1_FileDocument()
    document.path = filename; document.name = filename; document.content = "# Document"
    document.binary = !["md", "swift"].contains(file.pathExtension)
    model.fileDocument = document
    model.fileEditorSession.prepare(documentKey: model.documentKey, text: document.content)
    let state = FileDocumentActionsTestState()
    var revealed: URL?
    let actions = FileDocumentActions(
        files: model, identifierPrefix: "file-actions-test",
        resolveExternalActions: {
            FileExternalActions.resolve(
                verifiedLocal: state.verifiedLocal, rootPath: directory.path, relativePath: filename)
        }, reveal: { revealed = $0 })
    let host = NSHostingView(rootView: actions)
    host.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: -3_000, y: -3_000, width: 500, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
        window.contentView = nil
        window.close()
    }
    host.layoutSubtreeIfNeeded()

    let mounted = await waitForDocumentAction {
        documentActionButtons(in: host).count == 1
            && documentActionButtons(in: host).first?.isEnabled == true
    }
    #expect(mounted)
    let local = try #require(documentActionButtons(in: host).first)
    #expect(local.window === window && !local.isHiddenOrHasHiddenAncestor && local.bounds.width > 0)
    // Native smoke exercises the actual rendered controls. Here invoke their
    // shared handler to verify click-time path revalidation independently of
    // SwiftUI's private button dispatch machinery.
    actions.showInFinder()
    #expect(revealed == file.resolvingSymlinksInPath())

    state.verifiedLocal = false
    let disabled = await waitForDocumentAction {
        documentActionButtons(in: host).first?.isEnabled == false
            && documentActionButtons(in: host).count == (file.pathExtension == "md" ? 1 : 2)
    }
    #expect(disabled)
    let remote = try #require(documentActionButtons(in: host).first)
    #expect(remote.window === window && !remote.isHiddenOrHasHiddenAncestor && remote.bounds.width > 0)
    revealed = nil
    actions.showInFinder()
    #expect(revealed == nil)
    if file.pathExtension != "md" {
        #expect(documentActionButtons(in: host).last?.isEnabled == true)
    }
}

@MainActor @Observable private final class FileDocumentActionsTestState {
    var verifiedLocal = true
}

@MainActor private func documentActionButtons(in host: NSView) -> [NSButton] {
    // The hosted unit process mounts real AppKit controls but does not publish
    // SwiftUI's virtual accessibility labels/identifiers. The packaged native
    // smoke checks those semantics; here press the actual toolbar controls.
    // Finder is the first action, followed by a plain Save a Copy button when
    // unavailable. Markdown's Export menu is a separate NSPopUpButton.
    var pending = [host]
    var buttons: [NSButton] = []
    while let view = pending.popLast() {
        if let button = view as? NSButton, !(button is NSPopUpButton) { buttons.append(button) }
        pending.append(contentsOf: view.subviews)
    }
    return buttons.sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
}

@MainActor private func waitForDocumentAction(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<50 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
