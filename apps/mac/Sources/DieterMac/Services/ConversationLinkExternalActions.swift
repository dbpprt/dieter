import AppKit
import DieterAPI
import Foundation
import UniformTypeIdentifiers

extension DieterStore {
    @MainActor
    func externalConversationLink(_ url: URL, cardID: String) async -> ConversationLinkExternalTarget {
        let isWeb = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        guard (selectedCardID ?? selectedChatID) == cardID else {
            return .unavailable("This conversation's machine is unavailable.", isFile: !isWeb)
        }
        let selectedRPC = rpc
        let endpointID = endpoint.id
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return (self.selectedCardID ?? self.selectedChatID) == cardID
                && self.endpoint.id == endpointID && self.rpc === selectedRPC
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
        guard let rpc = selectedRPC else { return .unavailable("This conversation's machine is unavailable.") }
        do {
            let scope = try await conversationContext.content.prepareScope(cardID)
            guard isCurrent(), scope.client === rpc, scope.target.endpointID == endpointID,
                scope.target.conversationID == cardID
            else { return .unavailable("This conversation's machine is no longer selected.") }
            guard case .file(let path, _) = try ConversationContentLink.resolve(url, workspaceRoot: scope.rootPath)
            else {
                return .unavailable("This link does not identify a workspace file.")
            }
            let verifiedLocal = phase.isConnected && rpc.isLoopbackDataPlane
            if !verifiedLocal {
                let copy = try await remoteDocumentCopies.fetch(
                    client: scope.client, target: scope.target, path: path, isCurrent: isCurrent)
                return ConversationLinkExternalTarget(
                    isLocalCopy: true, applications: FileOpeningApplication.available(for: copy),
                    revalidate: {
                        guard isCurrent(), FileManager.default.fileExists(atPath: copy.path) else { return nil }
                        return copy
                    })
            }
            var actions = FileExternalActions.resolve(
                verifiedLocal: verifiedLocal, rootPath: scope.rootPath, relativePath: path)
            actions.loadApplications()
            let reason = actions.unavailableReason.map { _ in
                verifiedLocal
                    ? "This file is unavailable locally. Open in Dieter to inspect it."
                    : "This file is on another machine. Download it or open it in Dieter."
            }
            var downloadFile: (@MainActor () -> Void)?
            if rpc.isLoopbackDataPlane {
                downloadFile = nil
            } else {
                downloadFile = { [weak self] in
                    guard isCurrent(), let self, self.phase.isConnected else { return }
                    self.downloadConversationFile(
                        path: path, projectID: scope.target.projectID, cardID: cardID, rpc: rpc)
                }
            }
            return ConversationLinkExternalTarget(
                applications: actions.applications, unavailableReason: reason, downloadFile: downloadFile,
                revalidate: { [weak self] in
                    guard isCurrent(), self?.phase.isConnected == true, rpc.isLoopbackDataPlane else { return nil }
                    return FileExternalActions.resolve(
                        verifiedLocal: true, rootPath: scope.rootPath, relativePath: path
                    ).fileURL
                })
        } catch { return .unavailable(error.localizedDescription) }
    }

    @MainActor
    private func downloadConversationFile(path: String, projectID: String, cardID: String, rpc: DieterRPC) {
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
                var request = Dieter_V1_ReadFileRequest()
                request.projectID = projectID
                request.cardID = cardID
                request.path = path
                let document = try await rpc.readFile(request)
                let bytes = ProjectFilePresentation.bytes(
                    binary: document.binary, content: document.content, data: document.data)
                try bytes.write(to: destination, options: .atomic)
            } catch {
                self?.errorMessage = "Could not download \(filename): \(DieterRPCFailure.message(for: error))"
            }
        }
    }
}
