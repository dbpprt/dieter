import DieterAPI
import Foundation
import Testing
@testable import DieterMac

private actor ScheduleMutationFixture: DieterScheduleRPC, ScheduleCommandsRPC {
    var pending: CheckedContinuation<Dieter_V1_Schedule, Never>?
    var submitted: Dieter_V1_SaveScheduleRequest?
    var waiting: Bool { pending != nil }
    func schedules(projectID: String, pageSize: Int32, pageToken: String) async throws -> Dieter_V1_SchedulesResponse {
        var schedule = Dieter_V1_Schedule(); schedule.id = projectID; schedule.projectID = projectID
        var response = Dieter_V1_SchedulesResponse(); response.schedules = [schedule]; response.totalCount = 1
        return response
    }
    func scheduleRuns(id: String, pageSize: Int32, pageToken: String) async throws -> Dieter_V1_ScheduleRunsResponse {
        .init()
    }
    func createSchedule(_ request: Dieter_V1_SaveScheduleRequest) async throws -> Dieter_V1_Schedule {
        submitted = request
        return await withCheckedContinuation { pending = $0 }
    }
    func updateSchedule(_ request: Dieter_V1_SaveScheduleRequest) async throws -> Dieter_V1_Schedule {
        try await createSchedule(request)
    }
    func deleteSchedule(id: String) async throws {}
    func runSchedule(id: String) async throws -> Dieter_V1_ScheduleRun { .init() }
    func setScheduleEnabled(id: String, enabled: Bool) async throws -> Dieter_V1_Schedule { .init() }
    func previewSchedule(_ request: Dieter_V1_PreviewScheduleRequest) async throws -> Dieter_V1_SchedulePreview {
        .init()
    }
    func finish() {
        var value = Dieter_V1_Schedule(); value.id = "created"; value.projectID = submitted!.schedule.projectID
        pending?.resume(returning: value); pending = nil
    }
}

@Test @MainActor func scheduleSaveCannotSelectOrInsertIntoAnotherProjectAfterNavigation() async throws {
    let client = ScheduleMutationFixture(), model = SchedulesModel()
    model.bind(target: .init(endpointID: "machine", projectID: "A"), reader: client, writer: client)
    await model.loadSchedules()
    var draft = Dieter_V1_ScheduleDraft(); draft.projectID = "A"
    let value = draft
    let save = Task { await model.saveSchedule(id: nil, draft: value) }
    for _ in 0..<1_000 {
        if await client.waiting { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(await client.waiting)
    model.bind(target: .init(endpointID: "machine", projectID: "B"), reader: client, writer: client)
    await model.loadSchedules()
    await client.finish()
    #expect(await save.value == false)
    #expect(model.schedules.map(\.id) == ["B"])
    #expect(model.selectedScheduleID == "B")
    #expect(model.errorMessage == nil)
}

@Test @MainActor func workspaceCardUpsertUpdatesItsProjectAndDoesNotInventABoardDictionaryKey() {
    let store = DieterStore(restoreSync: false)
    var card = Dieter_V1_Card(); card.id = "card"; card.projectID = "project"; card.boardID = "board";
    card.runtime = "queued"
    store.state.cards = [card]
    store.navigationCards = [card.projectID: [card]]
    card.runtime = "ready"
    store.acceptWorkspaceCard(card)
    #expect(store.state.cards.first?.runtime == "ready")
    #expect(store.navigationCards["project"]?.first?.runtime == "ready")
    #expect(store.navigationCards["board"] == nil)
    store.updateSelectedState()
    #expect(store.navigationCards["project"]?.first?.runtime == "ready")
}
