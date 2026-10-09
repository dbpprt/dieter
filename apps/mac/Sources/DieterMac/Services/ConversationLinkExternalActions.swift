import AppKit
import DieterAPI
import Foundation
import SharedCore
import UniformTypeIdentifiers

extension DieterStore {
    @MainActor
    func externalConversationLink(_ url: URL, cardID: String) async -> ConversationLinkExternalTarget {
        let isWeb = ConversationContentLink.isWeb(url)
        guard (selectedCardID ?? selectedChatID) == cardID, phase.isConnected else {
            return .unavailable("This conversation's machine is unavailable.", isFile: !isWeb)
        }
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return (self.selectedCardID ?? self.selectedChatID) == cardID && self.phase.isConnected
        }
        if isWeb {
            guard case .web = try? ConversationContentLink.resolve(url, workspaceRoot: "") else {
                return .unavailable("This web link is invalid.", isFile: false)
            }
            do { try conversationContext.content.validateWebURL(url, cardID) } catch {
                return .unavailable(error.localizedDescription, isFile: false)
            }
            return ConversationLinkExternalTarget(
                isFile: false, applications: FileOpeningApplication.available(for: url),
                revalidate: { [weak self] in
                    guard isCurrent(), let self else { return nil }
                    do {
                        try self.conversationContext.content.validateWebURL(url, cardID)
                        return url
                    } catch { return nil }
                })
        }
        do {
            let scope = try await conversationContext.content.prepareScope(cardID)
            guard isCurrent(), scope.target.conversationID == cardID
            else { return .unavailable("This conversation is no longer selected.") }
            guard case .file(let path, _) = try ConversationContentLink.resolve(url, workspaceRoot: scope.rootPath)
            else {
                return .unavailable("This link does not identify a workspace file.")
            }
            let verifiedLocal = isLocalMachine(scope.target.endpointID)
            var actions = FileExternalActions.resolve(
                verifiedLocal: verifiedLocal, rootPath: scope.rootPath, relativePath: path)
            actions.loadApplications()
            let reason = actions.unavailableReason.map { _ in
                verifiedLocal
                    ? "This file is unavailable locally. Open in Dieter to inspect it."
                    : "This file is on another machine. Download it or open it in Dieter."
            }
            var downloadFile: (@MainActor () -> Void)?
            if verifiedLocal {
                downloadFile = nil
            } else {
                downloadFile = { [weak self] in
                    guard isCurrent(), let self, self.phase.isConnected else { return }
                    self.downloadConversationFile(
                        path: path, daemonID: scope.target.daemonID, projectID: scope.target.projectID, cardID: cardID)
                }
            }
            return ConversationLinkExternalTarget(
                applications: actions.applications, unavailableReason: reason, downloadFile: downloadFile,
                revalidate: { [weak self] in
                    guard isCurrent(), self?.isLocalMachine(scope.target.endpointID) == true else { return nil }
                    return FileExternalActions.resolve(
                        verifiedLocal: true, rootPath: scope.rootPath, relativePath: path
                    ).fileURL
                })
        } catch { return .unavailable(error.localizedDescription) }
    }

    /// Reads the file on the conversation's machine and saves it here.
    @MainActor
    private func downloadConversationFile(path: String, daemonID: String, projectID: String, cardID: String) {
        let filename = (path as NSString).lastPathComponent
        let panel = NSSavePanel()
        panel.title = "Download File"
        panel.prompt = "Download"
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: (filename as NSString).pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                let document = try await self.administer {
                    $0.readFile = .with {
                        $0.daemonID = daemonID
                        $0.projectID = projectID
                        $0.cardID = cardID
                        $0.path = path
                    }
                }.fileDocument
                try document.bytes.write(to: destination, options: .atomic)
            } catch {
                self?.errorMessage =
                    "Could not download \(filename): \((error as? CoreFailure)?.message ?? error.localizedDescription)"
            }
        }
    }
}
