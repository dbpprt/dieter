import DieterAPI
import DieterCore
import Foundation
import Testing
@testable import DieterMac

private actor ProcessFixture: ProcessesRPC {
    var values: [Dieter_V1_Execution]
    var receivers: [String: @Sendable (Dieter_V1_ExecutionEvent) async -> Void] = [:]
    private(set) var scopes: [String] = []
    private(set) var stops = 0
    private(set) var canceledWatches = 0

    init(values: [Dieter_V1_Execution]) { self.values = values }
    func executions(projectID: String, cardID: String) async throws -> Dieter_V1_ExecutionsResponse {
        scopes.append("\(projectID)/\(cardID)")
        var response = Dieter_V1_ExecutionsResponse(); response.executions = values; return response
    }
    func watchExecution(
        id: String, after: UInt64, receive: @escaping @Sendable (Dieter_V1_ExecutionEvent) async -> Void
    ) async throws {
        receivers[id] = receive
        do { try await Task.sleep(for: .seconds(60)) } catch { canceledWatches += 1; throw error }
    }
    func cancelExecution(id: String) async throws -> Dieter_V1_Execution {
        stops += 1
        var value = values.first { $0.id == id }!; value.status = "canceled"; value.sequence += 1
        return value
    }
    func watching(_ id: String) -> Bool { receivers[id] != nil }
    func emit(_ event: Dieter_V1_ExecutionEvent) async { await receivers[event.execution.id]?(event) }
}

@MainActor struct ConversationProcessesModelTests {
    private func execution(_ id: String, card: String = "card") -> Dieter_V1_Execution {
        var value = Dieter_V1_Execution()
        value.id = id; value.projectID = "project"; value.cardID = card; value.status = "running"; value.name = id
        return value
    }
    private func wait(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func processScopeOutputAndExplicitStopStayBounded() async {
        let own = execution("own")
        let fixture = ProcessFixture(values: [own, execution("foreign", card: "other")])
        let model = ConversationProcessesModel()
        model.bind(target: .init(endpointID: "machine", projectID: "project", conversationID: "card"), client: fixture)
        model.active = true
        defer { model.active = false }
        #expect(await wait { await fixture.watching("own") })
        #expect(model.processes.map(\.id) == ["own"])
        #expect(await fixture.scopes.first == "project/card")
        var event = Dieter_V1_ExecutionEvent(); event.execution = own; event.sequence = 1
        event.stream = .stdout; event.data = Data(repeating: 65, count: ConversationProcessesModel.maximumOutputBytes)
        await fixture.emit(event)
        event.sequence = 2; event.stream = .stderr; event.data = Data("warning".utf8)
        await fixture.emit(event)
        #expect(model.stdout.count <= ConversationProcessesModel.maximumOutputBytes / 2)
        #expect(model.outputTruncated && String(decoding: model.stderr, as: UTF8.self) == "warning")
        model.active = false
        #expect(await wait { await fixture.canceledWatches == 1 })
        #expect(await fixture.stops == 0, "Hiding or closing only detaches the watch")
        model.active = true
        await model.stopSelected()
        #expect(await fixture.stops == 1)
        #expect(model.selected?.status == "canceled")
    }

    @Test func staleProcessOutputCannotCrossMachineOrConversation() async {
        let old = execution("old")
        let first = ProcessFixture(values: [old])
        let second = ProcessFixture(values: [execution("new", card: "next")])
        let model = ConversationProcessesModel()
        model.bind(target: .init(endpointID: "first", projectID: "project", conversationID: "card"), client: first)
        model.active = true
        defer { model.active = false }
        #expect(await wait { await first.watching("old") })
        model.bind(target: .init(endpointID: "second", projectID: "project", conversationID: "next"), client: second)
        #expect(await wait { await second.watching("new") })
        var late = Dieter_V1_ExecutionEvent(); late.execution = old; late.sequence = 99
        late.stream = .stdout; late.data = Data("old machine output".utf8)
        await first.emit(late)
        #expect(model.selectedID == "new" && model.stdout.isEmpty)
        #expect(await first.stops == 0)
    }

    @Test func releasingActiveProcessModelCancelsObserversWithoutStoppingProcess() async {
        let fixture = ProcessFixture(values: [execution("own")])
        var model: ConversationProcessesModel? = ConversationProcessesModel()
        weak var released = model
        model?.bind(target: .init(endpointID: "machine", projectID: "project", conversationID: "card"), client: fixture)
        model?.active = true
        #expect(await wait { await fixture.watching("own") })
        model = nil
        #expect(
            await wait {
                let canceled = await fixture.canceledWatches; return released == nil && canceled == 1
            })
        #expect(await fixture.stops == 0)
    }
}
