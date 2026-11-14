import AppKit
import UniformTypeIdentifiers

/// The draft owns its picker independently of the transient SwiftUI popover.
/// A native file panel may dismiss that popover when it takes keyboard focus.
@MainActor
final class QuickTaskFilePicker {
    private var panel: NSOpenPanel?

    func selectFiles() async -> [URL]? {
        guard panel == nil else { return nil }
        let panel = NSOpenPanel()
        panel.title = "Attach files"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.item]
        self.panel = panel
        return await withCheckedContinuation { continuation in
            panel.begin { [weak self] response in
                if self?.panel === panel { self?.panel = nil }
                continuation.resume(returning: response == .OK ? panel.urls : nil)
            }
        }
    }

    func cancel() {
        panel?.cancel(nil)
        panel = nil
    }
}
