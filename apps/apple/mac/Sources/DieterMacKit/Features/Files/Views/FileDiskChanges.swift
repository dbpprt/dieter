import DieterPlatform
import SwiftUI

/// Checks through the shared core only while this document surface is visible.
struct FileDiskRefresh: ViewModifier {
    let files: FilesModel
    var active = true
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: "\(files.documentKey):\(files.isLive):\(active):\(scenePhase == .active)") {
            guard active, scenePhase == .active, files.isLive, !files.documentKey.isEmpty else { return }
            while !Task.isCancelled {
                await files.refreshCurrentDocument()
                do { try await DieterTaskSleep.seconds(2) } catch { return }
            }
        }
    }
}

struct FileDiskConflictBanner: View {
    let files: FilesModel
    var active = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(files.fileError ?? "This file changed on disk while you had unsaved edits.")
                .font(.callout).textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Reload from Disk") { Task { await files.reloadDocument() } }
                    .help("Discard your unsaved edits and load the version on disk")
                    .accessibilityIdentifier("files.reload").e2eTarget("files.reload")
                Button("Overwrite Disk") { Task { await files.overwriteCurrentDocument() } }
                    .help("Replace the disk version with your current edits")
                    .accessibilityIdentifier("files.overwrite").e2eTarget("files.overwrite")
            }
            .buttonStyle(DieterBarButtonStyle(size: 28))
            .disabled(!active || !files.isLive || files.saving || files.fileLoading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(DieterTheme.amber.opacity(0.1))
        .accessibilityIdentifier("files.disk-conflict")
        .e2eTarget("files.disk-conflict")
    }
}
