#if os(iOS)
    import DieterAPI
    import DieterShared
    import Foundation
    import UIKit

    /// The general pasteboard as screen sharing's clipboard sync reads and
    /// writes it: plain text only. The core calls from its own threads;
    /// UIKit's pasteboard is used on the main thread.
    package final class CoreUIPasteboardClipboard: NSObject, NativeClipboard, Sendable {
        package func stamp() -> Int64 { onMainThread { Int64(UIPasteboard.general.changeCount) } }

        package func read(binary: Bool) -> Data? {
            onMainThread {
                guard let text = UIPasteboard.general.string, !text.isEmpty else { return nil }
                return try? ClientClipboardContent.with { $0.text = text }.serializedData()
            }
        }

        package func apply(content: Data) {
            guard let value = try? ClientClipboardContent(serializedBytes: content), !value.text.isEmpty else { return }
            let text = value.text
            onMainThread { UIPasteboard.general.string = text }
        }
    }
#endif
