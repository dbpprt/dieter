import AppKit
import CoreGraphics
import Foundation

// Independent of the capture process, so another app's lazy pasteboard provider
// can never stall video, frame credits, input ACKs or the capture watchdog.
enum ClipboardService {
    struct Request: Decodable { var action: Int; var text: String; var knownRevision: String; var items: [ScreenClipboardItem]?; var acceptBinary: Bool? }
    struct Reply: Encodable {
        var revision = ""
        var text = ""
        var changed = false
        var hasText = false
        var error = ""
        var items: [ScreenClipboardItem] = []
    }
    static func run() {
        let args = CommandLine.arguments
        let name = args.firstIndex(of: "--clipboard-name").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let dryRun = args.contains("--dry-run") && name?.hasPrefix("com.dbpprt.dieter.fixture.") == true
        let pasteboard = name.map { NSPasteboard(name: .init($0)) } ?? .general
        let directory = args.firstIndex(of: "--clipboard-directory").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1], isDirectory: true) : nil } ?? ScreenClipboardContent.defaultDirectory
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 16 * 1024 * 1024 else { return }
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer[..<end]; buffer.removeSubrange(...end)
                var reply = Reply()
                do {
                    let request = try JSONDecoder().decode(Request.self, from: line)
                    let content = ScreenClipboardContent(text: (request.items ?? []).isEmpty ? request.text : nil, items: request.items ?? [])
                    try content.validate()
                    switch request.action {
                    case 0:
                        reply.revision = String(pasteboard.changeCount)
                        reply.changed = request.knownRevision != reply.revision
                        if reply.changed {
                            let value = try ScreenClipboardContent.read(pasteboard, binary: request.acceptBinary == true)
                            reply.hasText = value.text != nil; reply.text = value.text ?? ""; reply.items = value.items
                        }
                    case 1, 2:
                        if request.action == 2 && !dryRun && !CGPreflightPostEventAccess() {
                            throw CaptureError.invalidArgument("Accessibility permission is required to paste")
                        }
                        try content.write(pasteboard, directory: directory)
                        reply.revision = String(pasteboard.changeCount); reply.hasText = content.text != nil
                        if request.action == 2 && !dryRun { try shortcut(9) }
                    case 4, 5:
                        let previous = pasteboard.changeCount
                        if !dryRun {
                            try shortcut(request.action == 4 ? 8 : 7)
                            let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
                            while pasteboard.changeCount == previous && DispatchTime.now().uptimeNanoseconds < deadline { usleep(5_000) }
                            guard pasteboard.changeCount != previous else { throw CaptureError.invalidArgument("remote application did not copy content") }
                        }
                        reply.revision = String(pasteboard.changeCount)
                        let value = try ScreenClipboardContent.read(pasteboard, binary: request.acceptBinary == true)
                        reply.hasText = value.text != nil; reply.text = value.text ?? ""; reply.items = value.items; reply.changed = true
                    default: throw CaptureError.invalidArgument("clipboard action")
                    }
                } catch { reply.error = error.localizedDescription }
                if let data = try? JSONEncoder().encode(reply) {
                    FileHandle.standardOutput.write(data + Data([10]))
                }
            }
        }
    }
    private static func shortcut(_ code: CGKeyCode) throws {
        guard CGPreflightPostEventAccess() else { throw CaptureError.invalidArgument("Accessibility permission is required") }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                throw CaptureError.invalidArgument("clipboard shortcut")
            }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }
}
