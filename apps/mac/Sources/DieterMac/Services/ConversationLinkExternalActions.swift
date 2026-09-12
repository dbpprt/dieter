import AppKit
import Foundation

extension DieterStore {
    @MainActor
    func externalConversationLink(_ url: URL, cardID: String) async -> ConversationLinkExternalTarget {
        let isWeb = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        guard (selectedCardID ?? selectedChatID) == cardID, let rpc else {
            return .unavailable("This conversation's machine is unavailable.", isFile: !isWeb)
        }
        let endpointID = endpoint.id
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return (self.selectedCardID ?? self.selectedChatID) == cardID
                && self.endpoint.id == endpointID && self.rpc === rpc
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
            guard isCurrent(), scope.client === rpc, scope.target.endpointID == endpointID,
                scope.target.conversationID == cardID
            else { return .unavailable("This conversation's machine is no longer selected.") }
            guard case .file(let path, _) = try ConversationContentLink.resolve(url, workspaceRoot: scope.rootPath)
            else {
                return .unavailable("This link does not identify a workspace file.")
            }
            let verifiedLocal = phase.isConnected && rpc.isLoopbackDataPlane
            var actions = FileExternalActions.resolve(
                verifiedLocal: verifiedLocal, rootPath: scope.rootPath, relativePath: path)
            actions.loadApplications()
            let reason = actions.unavailableReason.map { _ in
                verifiedLocal
                    ? "This file is unavailable locally. Open in Dieter to inspect it."
                    : "This file is on another machine. Open in Dieter to save a local copy."
            }
            return ConversationLinkExternalTarget(
                applications: actions.applications, unavailableReason: reason,
                revalidate: { [weak self] in
                    guard isCurrent(), self?.phase.isConnected == true, rpc.isLoopbackDataPlane else { return nil }
                    return FileExternalActions.resolve(
                        verifiedLocal: true, rootPath: scope.rootPath, relativePath: path
                    ).fileURL
                })
        } catch { return .unavailable(error.localizedDescription) }
    }
}
