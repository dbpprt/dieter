import DieterAPI
import Foundation
import SharedCore
import Testing
@testable import DieterMac

@Test @MainActor func readReceiptRequiresLoadedReplyAndCurrentSelection() async {
    let core = ScriptedCoreClient()
    let model = ConversationModel()
    model.core = core
    model.selectedChatID = "chat"
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.detail.card.id = "chat"
    snapshot.detail.card.scope = "chat"
    snapshot.detail.card.responseSeq = 40
    snapshot.detail.card.responseMessageID = "reply"
    model.conversation = snapshot
    func receipts() -> [String] { core.commands.compactMap { if case .markCardRead(let read) = $0.command { read.cardID } else { nil } } }
    await model.markResponseSeen()
    #expect(receipts().isEmpty)
    snapshot.conversation.messages = [fixtureMessage("reply", role: "assistant")]
    // Directory metadata can announce completion before the final transcript frame arrives.
    snapshot.conversation.lastSeq = 39
    model.conversation = snapshot
    await model.markResponseSeen()
    #expect(receipts().isEmpty)
    snapshot.conversation.lastSeq = 40
    model.conversation = snapshot
    model.browsingEarlierHistory = true
    await model.markResponseSeen()
    #expect(receipts().isEmpty)
    model.browsingEarlierHistory = false
    model.selectedChatID = "other"
    await model.markResponseSeen()
    #expect(receipts().isEmpty)
    model.selectedChatID = "chat"
    await model.markResponseSeen()
    #expect(receipts() == ["chat"])
    // The core confirms through the card; a seen reply is not sent again.
    snapshot.detail.card.seenResponseSeq = 40
    model.conversation = snapshot
    await model.markResponseSeen()
    #expect(receipts() == ["chat"])
}
