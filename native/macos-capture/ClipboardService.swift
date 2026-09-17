import AppKit
import CoreGraphics
import Foundation

// Independent of the capture process, so another app's lazy pasteboard provider
// can never stall video, frame credits, input ACKs or the capture watchdog.
enum ClipboardService {
    struct Request: Decodable { var action: Int; var text: String; var knownRevision: String }
    struct Reply: Encodable {
        var revision = ""
        var text = ""
        var changed = false
        var hasText = false
        var error = ""
    }
    static func run() {
        let args = CommandLine.arguments
        let name = args.firstIndex(of: "--clipboard-name").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let dryRun = args.contains("--dry-run") && name?.hasPrefix("com.dbpprt.dieter.fixture.") == true
        let pasteboard = name.map { NSPasteboard(name: .init($0)) } ?? .general
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 8 * 1024 * 1024 else { return }
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer[..<end]; buffer.removeSubrange(...end)
                var reply = Reply()
                do {
                    let request = try JSONDecoder().decode(Request.self, from: line)
                    guard request.text.utf8.count <= 1024 * 1024 else { throw CaptureError.invalidArgument("clipboard exceeds 1 MiB") }
                    switch request.action {
                    case 0:
                        reply.revision = String(pasteboard.changeCount)
                        reply.changed = request.knownRevision != reply.revision
                        // Metadata is safe to inspect without fetching another app's payload.
                        reply.hasText = pasteboard.availableType(from: [.string]) != nil
                        if reply.changed && reply.hasText {
                            guard let text = pasteboard.string(forType: .string) else {
                                throw CaptureError.invalidArgument("clipboard access denied or unavailable")
                            }
                            guard text.utf8.count <= 1024 * 1024 else { throw CaptureError.invalidArgument("clipboard exceeds 1 MiB") }
                            reply.text = text
                        }
                    case 1, 2:
                        if request.action == 2 && !dryRun && !CGPreflightPostEventAccess() {
                            throw CaptureError.invalidArgument("Accessibility permission is required to paste")
                        }
                        pasteboard.clearContents()
                        guard pasteboard.setString(request.text, forType: .string) else {
                            throw CaptureError.invalidArgument("clipboard write failed")
                        }
                        reply.revision = String(pasteboard.changeCount); reply.hasText = true
                        if request.action == 2 && !dryRun { try shortcut(9) }
                    case 4, 5:
                        let previous = pasteboard.changeCount
                        if !dryRun {
                            try shortcut(request.action == 4 ? 8 : 7)
                            let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
                            while pasteboard.changeCount == previous && DispatchTime.now().uptimeNanoseconds < deadline { usleep(5_000) }
                            guard pasteboard.changeCount != previous else { throw CaptureError.invalidArgument("remote application did not copy text") }
                        }
                        reply.revision = String(pasteboard.changeCount)
                        reply.hasText = pasteboard.availableType(from: [.string]) != nil
                        if reply.hasText {
                            guard let text = pasteboard.string(forType: .string), text.utf8.count <= 1024 * 1024 else {
                                throw CaptureError.invalidArgument("clipboard text unavailable or exceeds 1 MiB")
                            }
                            reply.text = text; reply.changed = true
                        }
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
