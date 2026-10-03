import AppKit
import DieterAPI
import DieterShared
import DieterTransport
import Foundation
import Metal
import SharedCore
@preconcurrency import WebRTC

/// The Mac's screen renderer: the Metal view draws every decoded frame.
extension RemoteDesktopMetalView: ScreenRenderer {
    nonisolated var presentationCounters: ScreenPresentationCounters {
        let snapshot = renderSnapshot
        return ScreenPresentationCounters(
            framesPresented: snapshot.framesPresented, totalRenderMilliseconds: snapshot.totalRenderMilliseconds)
    }
}

extension CoreScreenMedia {
    /// The Mac's engine: screens need Metal.
    static func mac() -> CoreScreenMedia {
        CoreScreenMedia { MTLCreateSystemDefaultDevice() == nil ? "Metal is unavailable on this Mac." : nil }
    }
}

/// The pasteboard as the core's clipboard sync reads and writes it. The core
/// calls from its own threads; AppKit's pasteboard is used on the main thread.
final class CoreScreenClipboard: NSObject, NativeClipboard, @unchecked Sendable {
    nonisolated(unsafe) var pasteboard: NSPasteboard
    nonisolated(unsafe) var stagingDirectory: URL

    init(pasteboard: NSPasteboard = .general, stagingDirectory: URL = ScreenClipboardContent.defaultDirectory) {
        self.pasteboard = pasteboard
        self.stagingDirectory = stagingDirectory
    }

    func stamp() -> Int64 { Self.onMain { Int64(self.pasteboard.changeCount) } }

    func read(binary: Bool) -> Data? {
        Self.onMain {
            guard let content = try? ScreenClipboardContent.read(self.pasteboard, binary: binary),
                content.text != nil || !content.items.isEmpty
            else { return nil }
            var value = ClientClipboardContent()
            value.text = content.text ?? ""
            value.items = content.items.map { item in
                Dieter_V1_RemoteDesktopClipboardItem.with {
                    $0.kind = .init(rawValue: Int(item.kind)) ?? .file
                    $0.name = item.name
                    $0.mimeType = item.mimeType
                    $0.data = item.data
                }
            }
            return try? value.serializedData()
        }
    }

    func apply(content: Data) {
        guard let value = try? ClientClipboardContent(serializedBytes: content) else { return }
        let decoded = ScreenClipboardContent(
            text: value.text.isEmpty && !value.items.isEmpty ? nil : value.text,
            items: value.items.map {
                ScreenClipboardItem(kind: Int32($0.kind.rawValue), name: $0.name, mimeType: $0.mimeType, data: $0.data)
            })
        Self.onMain { try? decoded.write(self.pasteboard, directory: self.stagingDirectory) }
    }

    private static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T { onMainThread(body) }
}
