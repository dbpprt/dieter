import DieterAPI
import DieterCore
import Foundation
import Testing

struct OutboxDependencyTests {
    @Test(arguments: [false, true], [false, true])
    func followupsWaitForCreationAcknowledgementWithoutBlockingOtherCards(stableID: Bool, failed: Bool) throws {
        let now = Date(timeIntervalSince1970: 100)
        var creation = create(stableID: stableID)
        creation.state = failed ? .failed : .retrying
        creation.nextAttemptAt = failed ? nil : now.addingTimeInterval(10)
        let dependent = try send("followup", cardID: creation.optimisticID)
        let unrelated = try send("unrelated", cardID: "c_existing")
        let entries = [creation, dependent, unrelated]
        #expect(DieterOutboxPolicy.nextIndex(in: entries, endpointID: "machine", now: now) == 2)
        #expect(DieterOutboxPolicy.nextIndex(in: [creation, dependent], endpointID: "machine", now: now) == nil)

        creation.serverID = "c_accepted"
        #expect(DieterOutboxPolicy.nextIndex(in: [creation, dependent], endpointID: "machine", now: now) == 1)
    }

    @Test func blockedRetryDatesDoNotWakeWorkersAndOtherEndpointsStayIndependent() throws {
        let now = Date(timeIntervalSince1970: 100)
        var creation = create(stableID: true)
        creation.state = .failed
        var dependent = try send("followup", cardID: creation.optimisticID)
        dependent.state = .retrying
        dependent.nextAttemptAt = now.addingTimeInterval(-10)
        var entries = [creation, dependent]
        #expect(DieterOutboxPolicy.nextRetryDelay(in: entries, endpointID: "machine", now: now) == nil)
        #expect(DieterOutboxPolicy.nextRetryDelay(in: entries, endpointIDs: ["machine"], now: now) == nil)

        creation.state = .retrying
        creation.nextAttemptAt = now.addingTimeInterval(10)
        entries[0] = creation
        #expect(DieterOutboxPolicy.nextRetryDelay(in: entries, endpointID: "machine", now: now) == 10)
        #expect(DieterOutboxPolicy.nextRetryDelay(in: entries, endpointIDs: ["machine"], now: now) == 10)
        var otherMachine = dependent
        otherMachine.endpointID = "another-machine"
        entries.append(otherMachine)
        #expect(DieterOutboxPolicy.nextIndex(in: entries, endpointIDs: ["machine", "another-machine"], now: now) == 2)
    }

    @Test func legacyCreateAlsoBlocksFollowupUsingItsExpectedServerID() throws {
        var creation = create(stableID: false, kind: .createChat)
        creation.state = .failed
        let expected = try #require(
            DieterOutboxPolicy.expectedConversationID(clientID: creation.clientID, commandID: creation.commandID))
        let dependent = try send("followup", cardID: expected)
        #expect(DieterOutboxPolicy.nextIndex(in: [creation, dependent], endpointID: "machine") == nil)
    }

    private func create(stableID: Bool, kind: DieterOutboxEntry.Kind = .createCard) -> DieterOutboxEntry {
        let id = DieterOutboxPolicy.expectedConversationID(clientID: "client", commandID: "create")!
        return DieterOutboxEntry(
            commandID: "create", clientID: "client", endpointID: "machine", kind: kind,
            request: Data(), optimisticID: stableID ? id : "local_create", attempts: 0,
            createdAt: Date(timeIntervalSince1970: 1))
    }

    private func send(_ id: String, cardID: String) throws -> DieterOutboxEntry {
        var request = Dieter_V1_SendMessageRequest()
        request.cardID = cardID
        return DieterOutboxEntry(
            commandID: id, clientID: "client", endpointID: "machine", kind: .sendMessage,
            request: try request.serializedData(), optimisticID: "msg_" + id, attempts: 0,
            createdAt: Date(timeIntervalSince1970: 2))
    }
}
