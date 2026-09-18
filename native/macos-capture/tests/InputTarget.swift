import AppKit
import Foundation
import CryptoKit

final class InputTarget: NSView {
    let output: URL
    var keys: [String] = []
    var ups = 0
    var text = ""
    var scrolls = 0
    var latencyWhite: Bool?
    var clipboardFiles: [URL] = []
    var clipboardImage: Data?
    var pastedBinary: [[String: Any]] = []
    let clipboard: NSPasteboard = CommandLine.arguments.count > 3 ? NSPasteboard(name: .init(CommandLine.arguments[3])) : .general
    init(output: URL) { self.output = output; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if [18, 19].contains(event.keyCode) {
            latencyWhite = event.keyCode == 18; needsDisplay = true; report(); return
        }
        keys.append("\(event.keyCode):down")
        if event.modifierFlags.contains(.command), event.keyCode == 9 {
            clipboardFiles = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            clipboardImage = clipboard.data(forType: .png)
            if !clipboardFiles.isEmpty {
                pastedBinary = clipboardFiles.compactMap { url in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return ["name": url.lastPathComponent, "bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
                }
            } else if let data = clipboardImage {
                pastedBinary = [["name": "image", "bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]]
            } else { pastedBinary = []; text += clipboard.string(forType: .string) ?? "" }
        }
        else if event.modifierFlags.contains(.command), [7, 8].contains(event.keyCode) {
            clipboard.clearContents()
            if !clipboardFiles.isEmpty { clipboard.writeObjects(clipboardFiles as [NSURL]) }
            else if let data = clipboardImage { clipboard.setData(data, forType: .png) }
            else { clipboard.setString(text, forType: .string) }
            if event.keyCode == 7 { text = ""; clipboardFiles = []; clipboardImage = nil }
        }
        else {
            // Typing selects text in this owned fixture. An earlier binary
            // paste must not keep winning a later Copy after new text input.
            clipboardFiles = []; clipboardImage = nil
            text += event.characters ?? ""
        }
        report()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), [7, 8, 9].contains(event.keyCode) { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func scrollWheel(with event: NSEvent) { scrolls += 1; report() }
    override func keyUp(with event: NSEvent) { keys.append("\(event.keyCode):up"); report() }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseUp(with event: NSEvent) { ups += 1; report() }
    override func draw(_ dirtyRect: NSRect) {
        (latencyWhite.map { $0 ? NSColor.white : NSColor.black } ?? NSColor.systemTeal).setFill(); bounds.fill()
        if latencyWhite != nil { return }
        ("Dieter native input test" as NSString).draw(
            at: NSPoint(x: 20, y: 80),
            withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.white])
    }
    func report() {
        guard let window else { return }
        let point = window.convertToScreen(
            convert(NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1), to: nil)
        ).origin
        let main = CGDisplayBounds(CGMainDisplayID())
        let value: [String: Any] = [
            "pastedBinary": pastedBinary, "keys": keys, "ups": ups, "text": text, "scrolls": scrolls, "x": (point.x - main.minX) / main.width,
            "y": (main.height - point.y) / main.height, "active": NSApp.isActive,
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: value) {
            try? data.write(to: output, options: .atomic)
        }
    }
}

@main struct InputTargetApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 400, y: 300, width: 420, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.title = "Owned Dieter input fixture"; window.isReleasedWhenClosed = false
        let target = InputTarget(output: URL(fileURLWithPath: CommandLine.arguments[1]))
        window.contentView = target
        app.finishLaunching()
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(target)
        app.activate(ignoringOtherApps: true)
        let parent = CommandLine.arguments.count > 2 ? Int32(CommandLine.arguments[2]) ?? getppid() : getppid()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if kill(parent, 0) != 0 { app.terminate(nil) }
            target.report()
        }
        app.run()
    }
}
