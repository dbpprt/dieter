import DieterAPI
import DieterCore
import Foundation
import GRPCCore
import SharedCore
import Testing
@testable import DieterMac

@Test @MainActor func composerDraftsStayWithTheirConversationAndSendRevision() {
    let model = ComposerModel()
    let first = WorkspaceTarget(endpointID: "machine", projectID: "", conversationID: "A")
    let second = WorkspaceTarget(endpointID: "machine", projectID: "", conversationID: "B")
    model.select(first); model.draft.text = "A"
    let pending = model.draft, revision = model.draft.revision
    model.select(second); model.draft.text = "B"
    pending.acceptSend(revision: revision)
    #expect(model.draft.text == "B")
    model.select(first); #expect(model.draft.text.isEmpty)
    model.draft.text = "C"
    let priorRevision = model.draft.revision
    model.draft.text = "D"
    model.draft.acceptSend(revision: priorRevision)
    #expect(model.draft.text == "D")
}

@Test @MainActor func composerDraftTextSurvivesModelRelaunchForCardsAndChats() async {
    // The core keeps draft text on this device; this fake keeps what it was sent.
    var saved: [String: String] = [:]
    func core() -> ScriptedCoreClient {
        let core = ScriptedCoreClient()
        core.handler = { command in
            switch command.command {
            case .setDraftText(let set):
                saved[set.daemonID + "/" + set.cardID] = set.text.isEmpty ? nil : set.text
            case .listDrafts:
                return .with {
                    $0.drafts.drafts = saved.map { key, text in
                        let parts = key.split(separator: "/").map(String.init)
                        return .with {
                            $0.daemonID = parts[0]; $0.cardID = parts[1]; $0.text = text
                        }
                    }
                }
            default: break
            }
            return .with { $0.done = ClientDone() }
        }
        return core
    }
    let card = WorkspaceTarget(endpointID: "gateway#machine", projectID: "", conversationID: "card")
    let chat = WorkspaceTarget(endpointID: "gateway#machine", projectID: "", conversationID: "chat")

    let drafts = CoreDraftTexts(core: core())
    let model = ComposerModel(store: drafts)
    model.select(card)
    model.draft.text = "Unsent card draft"
    model.select(chat)
    model.draft.text = "Unsent All Chats draft"
    await drafts.save()
    #expect(saved == ["machine/card": "Unsent card draft", "machine/chat": "Unsent All Chats draft"])

    // A relaunched composer opened before the saved drafts arrive fills in.
    let relaunchedDrafts = CoreDraftTexts(core: core())
    let relaunched = ComposerModel(store: relaunchedDrafts)
    relaunched.select(card)
    #expect(relaunched.draft.text.isEmpty)
    await relaunchedDrafts.load()
    relaunched.adoptSavedTexts()
    #expect(relaunched.draft.text == "Unsent card draft")
    relaunched.select(chat)
    #expect(relaunched.draft.text == "Unsent All Chats draft")

    relaunched.draft.acceptSend(revision: relaunched.draft.revision)
    await relaunchedDrafts.save()
    #expect(saved == ["machine/card": "Unsent card draft"])
}

@Test func unrelatedResourceLimitsAndInvalidInputAreNotDiskPressure() {
    for message in ["concurrent stream limit reached", "global capacity exceeded", "invalid model"] {
        #expect(!DieterRPCFailure.isInsufficientStorage(message))
    }
    #expect(DieterRPCFailure.isPermanent(RPCError(code: .invalidArgument, message: "invalid model")))
    #expect(DieterRPCFailure.isPermanent(RPCError(code: .permissionDenied, message: "no space left on device")))
}
