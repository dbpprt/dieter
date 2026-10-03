import DieterAPI
import Foundation
import SharedCore
import Testing
@testable import DieterMac

/// The core marks a reply read once it is loaded and shown at the latest
/// position (`ConversationSession.markReadIfVisible`); the Mac only reports
/// which conversation is on screen.
@Test @MainActor func seenRepliesAreReportedForTheObservedSelectionOnly() async {
    let core = ScriptedCoreClient()
    let model = ConversationModel()
    model.core = core
    func visible() -> [String] {
        core.commands.compactMap {
            if case .setVisibleConversation(let visible) = $0.command { visible.cardID } else { nil }
        }
    }
    model.selectedChatID = "chat"
    await model.markResponseSeen()
    #expect(visible().isEmpty, "a conversation that is not observed yet is not reported")
    model.observe("chat")
    model.selectedChatID = "other"
    await model.markResponseSeen()
    #expect(visible().isEmpty, "another selection is not reported")
    model.selectedChatID = "chat"
    await model.markResponseSeen()
    #expect(visible() == ["chat"])
    model.observe(nil)
}
