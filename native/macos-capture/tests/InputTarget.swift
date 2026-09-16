import AppKit
import Foundation

final class InputTarget: NSView {
    let output: URL
    var keys: [String] = []
    var ups = 0
    var text = ""
    var scrolls = 0
    init(output: URL) { self.output = output; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        keys.append("\(event.keyCode):down")
        text += event.characters ?? ""
        report()
    }
    override func scrollWheel(with event: NSEvent) { scrolls += 1; report() }
    override func keyUp(with event: NSEvent) { keys.append("\(event.keyCode):up"); report() }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseUp(with event: NSEvent) { ups += 1; report() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemTeal.setFill(); bounds.fill()
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
            "keys": keys, "ups": ups, "text": text, "scrolls": scrolls, "x": (point.x - main.minX) / main.width,
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
