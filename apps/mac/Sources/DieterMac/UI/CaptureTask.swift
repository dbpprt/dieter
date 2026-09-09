import AppKit
import ApplicationServices
import DieterAPI
import SwiftUI

struct CaptureBrowserContext: Sendable {
    let url: String
    let browser: Bool

    static func validatedURL(_ value: String?) -> String? {
        guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        else { return nil }
        return url.absoluteString
    }

    static func hostname(_ value: String) -> String? {
        guard let value = validatedURL(value), let host = URL(string: value)?.host else { return nil }
        var normalized = host.lowercased()
        if normalized.hasSuffix(".") { normalized.removeLast() }
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        return normalized
    }

    func matchingProjects(_ projects: [Dieter_V1_Project]) -> [Dieter_V1_Project] {
        guard let host = Self.hostname(url) else { return [] }
        return projects.filter { !$0.archived && $0.hostnames.contains(host) }
    }

    func matchingBoards(_ boards: [Dieter_V1_Board]) -> [Dieter_V1_Board] {
        guard let host = Self.hostname(url) else { return [] }
        return boards.filter { $0.hostnames.contains(host) }
    }

    static func read(bundleID: String?, pid: pid_t?) async -> Self {
        guard let bundleID else { return Self(url: "", browser: false) }
        let chromium = [
            "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
            "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.operasoftware.Opera",
        ]
        let safari = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
        let browser =
            chromium.contains(bundleID) || safari.contains(bundleID) || bundleID.hasPrefix("org.mozilla.firefox")
        guard browser else { return Self(url: "", browser: false) }
        // Read browser chrome only, never page text or browsing history.
        if let pid, let url = accessibilityURL(pid: pid) { return Self(url: url, browser: true) }
        guard chromium.contains(bundleID) || safari.contains(bundleID) else { return Self(url: "", browser: true) }
        let expression =
            safari.contains(bundleID) ? "URL of current tab of front window" : "URL of active tab of front window"
        let value = await Task.detached {
            let script = NSAppleScript(
                source:
                    "with timeout of 10 seconds\ntell application id \"\(bundleID)\" to get \(expression)\nend timeout")
            var error: NSDictionary?
            return script?.executeAndReturnError(&error).stringValue
        }.value
        return Self(url: validatedURL(value) ?? "", browser: true)
    }

    private static func accessibilityURL(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        let root = unsafeDowncast(window, to: AXUIElement.self)
        func string(_ node: AXUIElement, _ key: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }
            return value as? String
        }
        if let url = validatedURL(string(root, kAXDocumentAttribute)) { return url }
        var nodes: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        let deadline = Date().addingTimeInterval(1)
        while !nodes.isEmpty && visited < 160 && Date() < deadline {
            let (node, depth) = nodes.removeFirst(); visited += 1
            AXUIElementSetMessagingTimeout(node, 0.05)
            let role = string(node, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" {
                if let url = validatedURL(string(node, "AXURL")) { return url }
                continue
            }
            let label = (string(node, kAXDescriptionAttribute) ?? "").lowercased()
            if role == kAXTextFieldRole
                && (label.contains("address") || label.contains("adresse") || label.contains("url")),
                let url = validatedURL(string(node, kAXValueAttribute))
            {
                return url
            }
            guard depth < 8 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                let children = children as? [AXUIElement]
            {
                nodes.append(contentsOf: children.prefix(max(0, 160 - visited - nodes.count)).map { ($0, depth + 1) })
            }
        }
        return nil
    }
}

enum CaptureTaskError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .failed(let detail): "Screen capture failed: \(detail)"
        }
    }
}

@MainActor
enum TaskScreenCapture {
    static func region() async throws -> URL? {
        // Tahoe can fail when interactive capture writes directly to a file.
        // Receive the native selection through the clipboard, then encode it here.
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let initialChangeCount = pasteboard.changeCount
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dieter-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("Screen capture.png")
        var keepFile = false
        defer { if !keepFile { try? FileManager.default.removeItem(at: directory) } }
        do {
            let result = try await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-s", "-x", "-c", "-t", "png"]
                process.standardOutput = FileHandle.nullDevice
                let errors = Pipe()
                process.standardError = errors
                try process.run()
                let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (
                    process.terminationStatus,
                    String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }.value
            guard result.0 == 0 else {
                if !result.1.isEmpty { throw CaptureTaskError.failed(result.1) }
                return nil  // Escape cancels the native region selector.
            }
            guard let png = capturedPNG(from: pasteboard, after: initialChangeCount) else {
                if pasteboard.changeCount == initialChangeCount { return nil }
                throw CaptureTaskError.failed("The selection did not return an image. Please try again.")
            }
            // Restore only after consuming a new capture, never on cancellation.
            pasteboard.clearContents()
            let restored = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
            try png.write(to: file, options: .atomic)
            keepFile = true
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func capturedPNG(from pasteboard: NSPasteboard, after changeCount: Int) -> Data? {
        guard pasteboard.changeCount != changeCount else { return nil }
        if let data = pasteboard.data(forType: .png), NSBitmapImageRep(data: data) != nil { return data }
        guard let data = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor
final class CaptureTaskController {
    private let store: DieterStore
    private var window: NSWindow?
    #if DIETER_UI_SMOKE
        var fixtureCapture: (URL, CaptureBrowserContext)?
    #endif
    private(set) var capturing = false

    init(store: DieterStore) { self.store = store }

    func capture(hideIsland: () -> Void, restoreIsland: @escaping () -> Void) {
        guard !capturing else { return }
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return
        }
        capturing = true
        let source = NSWorkspace.shared.frontmostApplication
        hideIsland()
        Task {
            defer { capturing = false; restoreIsland() }
            do {
                let browser: CaptureBrowserContext
                let capture: URL?
                #if DIETER_UI_SMOKE
                    if let fixtureCapture {
                        browser = fixtureCapture.1
                        capture = fixtureCapture.0
                        self.fixtureCapture = nil
                    } else {
                        browser = await CaptureBrowserContext.read(
                            bundleID: source?.bundleIdentifier, pid: source?.processIdentifier)
                        capture = try await TaskScreenCapture.region()
                    }
                #else
                    browser = await CaptureBrowserContext.read(
                        bundleID: source?.bundleIdentifier, pid: source?.processIdentifier)
                    capture = try await TaskScreenCapture.region()
                #endif
                guard let file = capture else { return }
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                let boards = store.projects.filter { !$0.archived }.flatMap { store.boards(for: $0.id) }
                let boardMatches = browser.matchingBoards(boards)
                let projectMatches = browser.matchingProjects(store.projects)
                if boardMatches.count == 1, let board = boardMatches.first {
                    await store.selectProject(board.projectID)
                    if store.selectedProjectID == board.projectID, store.phase.isConnected {
                        await store.selectBoard(board.id)
                    } else {
                        store.selectedProjectID = ""; store.selectedBoardID = ""
                    }
                } else if boardMatches.isEmpty, projectMatches.count == 1, let project = projectMatches.first {
                    await store.selectProject(project.id)
                } else {
                    // Stage the capture without guessing a destination.
                    store.selectedProjectID = ""
                    store.selectedBoardID = ""
                }
                let parts = try await store.attachmentParts([file])
                present(parts: parts, browser: browser)
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    func present(parts: [Dieter_V1_MessagePart], browser: CaptureBrowserContext) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 454, height: 640), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Capture task"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 454, height: 400)
        window.contentView = NSHostingView(
            rootView: CapturedTaskDraftView(
                parts: parts, browser: browser,
                dismiss: { [weak self] in
                    self?.window?.close(); self?.window = nil
                }
            ).environment(store))
        self.window = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct CapturedTaskDraftView: View {
    let parts: [Dieter_V1_MessagePart]
    let browser: CaptureBrowserContext
    let dismiss: () -> Void
    @State private var presented = true
    @State private var draft: QuickTaskFormState

    init(parts: [Dieter_V1_MessagePart], browser: CaptureBrowserContext, dismiss: @escaping () -> Void) {
        self.parts = parts
        self.browser = browser
        self.dismiss = dismiss
        let draft = QuickTaskFormState()
        draft.attachments = parts
        draft.sourceURL = browser.url
        _draft = State(initialValue: draft)
    }

    var body: some View {
        ScrollView {
            QuickTaskPopover(isPresented: $presented, draft: draft, capturedBrowser: browser.browser)
        }
        .glassEffect(.regular, in: Rectangle())
        .onChange(of: presented) { _, value in if !value { dismiss() } }
    }
}
