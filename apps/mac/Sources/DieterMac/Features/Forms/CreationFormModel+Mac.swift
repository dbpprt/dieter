import DieterAPI
import Foundation
import SharedCore

extension CreationFormModel {
    /// The workspace mode: the chosen one, else the one last chosen.
    var workspaceMode: ConversationWorkspaceMode {
        ConversationWorkspaceMode.projectMode(
            intent.workspaceMode.isEmpty ? preview.intent.workspaceMode : intent.workspaceMode)
    }

    /// Creates the conversation from the choices and attachments.
    func create(using store: DieterStore) async -> Bool {
        await create { intent, chat, submissionID in
            await store.createConversation(intent, chat: chat, submissionID: submissionID)
        }
    }
}
