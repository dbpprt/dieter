import DieterAPI
import DieterCore
import Foundation
import Testing
@testable import DieterMac

private func recallMessage(_ id: String, text: String) -> Dieter_V1_QueuedMessage {
    var part = Dieter_V1_MessagePart(); part.type = "text"; part.text = text
    var attachment = Dieter_V1_MessagePart()
    attachment.type = "file"; attachment.filename = "screenshot.png"
    attachment.mediaType = "image/png"; attachment.url = "data:image/png;base64,c2NyZWVuc2hvdA=="
    var message = Dieter_V1_QueuedMessage()
    message.id = id; message.parts = [part, attachment]
    message.selection.provider = "codex"; message.selection.model = "queued-model"
    message.selection.effort = "high"; message.selection.providerOptions = ["fast_mode": "true"]
    return message
}

@Test func queueRecallChoosesLastMessageOnlyForAnEmptyComposer() {
    let first = recallMessage("first", text: "Earlier")
    let last = recallMessage("last", text: "Nevermind")
    #expect(ComposerQueueRecall.newestMessage(text: "", attachments: [], queue: [first, last]) == last)
    #expect(ComposerQueueRecall.newestMessage(text: "", attachments: [], queue: []) == nil)
    for text in ["My draft", " ", "\n", "First line\nSecond line"] {
        #expect(ComposerQueueRecall.newestMessage(text: text, attachments: [], queue: [last]) == nil)
    }
    #expect(ComposerQueueRecall.newestMessage(text: "", attachments: [last.parts[1]], queue: [last]) == nil)
}

@Test @MainActor func queueRecallRestoresAuthoritativeContentsAttachmentsAndSettings() async throws {
    let draft = ConversationDraft()
    let displayed = recallMessage("last", text: "Old cached value")
    let authoritative = recallMessage("last", text: "Nevermind 🦊")
    let removed = try await draft.removeQueuedMessage(displayed, edit: true) { id in
        #expect(id == displayed.id)
        #expect(draft.text.isEmpty && draft.attachments.isEmpty)
        return authoritative
    }
    #expect(removed)
    #expect(draft.text == "Nevermind 🦊")
    #expect(draft.attachments == [authoritative.parts[1]])
    #expect(draft.provider == "codex" && draft.model == "queued-model" && draft.effort == "high")
    #expect(draft.providerOptions == ["fast_mode": "true"])
    #expect(draft.pendingQueueMessageIDs.isEmpty)
}

@Test @MainActor func queueRecallRetainsTheOriginDraftAcrossNavigationAndConcurrentTyping() async throws {
    let composer = ComposerModel()
    let origin = WorkspaceTarget(endpointID: "test", projectID: "", conversationID: "origin")
    let other = WorkspaceTarget(endpointID: "test", projectID: "", conversationID: "other")
    composer.select(origin)
    let draft = composer.draft
    let message = recallMessage("last", text: "Queued instruction")
    var newerAttachment = Dieter_V1_MessagePart()
    newerAttachment.type = "file"; newerAttachment.filename = "new.txt"
    let removed = try await draft.removeQueuedMessage(message, edit: true) { _ in
        // Leave while still empty: the pending request must keep this exact
        // draft in the per-conversation cache until its result arrives.
        composer.select(other)
        composer.draft.text = "Other conversation draft"
        composer.select(origin)
        #expect(composer.draft === draft)
        draft.text = "  New input while waiting\n"
        draft.attachments = [newerAttachment]
        composer.select(other)
        await Task.yield()
        return message
    }
    #expect(removed)
    #expect(composer.draft.text == "Other conversation draft")
    composer.select(origin)
    #expect(composer.draft === draft)
    #expect(draft.text == "Queued instruction\n\n  New input while waiting\n")
    #expect(draft.attachments == [message.parts[1], newerAttachment])
}

@Test @MainActor func queueRecallSerializesRepeatedKeysAndCompetingTrayActions() async throws {
    let draft = ConversationDraft()
    let message = recallMessage("last", text: "Nevermind")
    var requests = 0
    let removed = try await draft.removeQueuedMessage(message, edit: true) { _ in
        requests += 1
        let duplicate = try await draft.removeQueuedMessage(message, edit: true) { _ in
            requests += 1; return message
        }
        let competing = try await draft.removeQueuedMessage(recallMessage("other", text: "Earlier"), edit: false) { _ in
            requests += 1; return message
        }
        #expect(!duplicate && !competing)
        return message
    }
    #expect(removed && requests == 1)
    #expect(draft.text == "Nevermind" && draft.attachments.count == 1)
}

@Test @MainActor func queueRecallFailurePreservesDraftAndAllowsRetry() async throws {
    enum Failure: Error { case alreadyStarted }
    let draft = ConversationDraft()
    let message = recallMessage("last", text: "Nevermind")
    draft.model = "current-model"
    do {
        _ = try await draft.removeQueuedMessage(message, edit: true) { _ in
            draft.text = "Typed during request"
            throw Failure.alreadyStarted
        }
        Issue.record("A failed dequeue should throw")
    } catch Failure.alreadyStarted {}
    #expect(draft.text == "Typed during request" && draft.attachments.isEmpty)
    #expect(draft.model == "current-model" && draft.pendingQueueMessageIDs.isEmpty)
    let retried = try await draft.removeQueuedMessage(message, edit: true) { _ in message }
    #expect(retried && draft.text == "Nevermind\n\nTyped during request")
}

@Test @MainActor func queueRemovalDoesNotEditAndSendingDraftCannotBeRecalled() async throws {
    let draft = ConversationDraft()
    let message = recallMessage("last", text: "Nevermind")
    draft.text = "Keep this draft"
    let removed = try await draft.removeQueuedMessage(message, edit: false) { _ in message }
    #expect(removed && draft.text == "Keep this draft" && draft.attachments.isEmpty)
    draft.sending = true
    var called = false
    let recalled = try await draft.removeQueuedMessage(message, edit: true) { _ in
        called = true; return message
    }
    #expect(!recalled && !called && draft.text == "Keep this draft")
}
