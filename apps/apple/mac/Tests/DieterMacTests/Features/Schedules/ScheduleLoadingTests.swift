import DieterAPI
import DieterMacTestSupport
import Testing
@testable import DieterMacKit

private actor ScheduleRPCStub: DieterScheduleRPC {
    let schedulesResponses: [String: Dieter_V1_SchedulesResponse]
    let runsResponses: [String: Dieter_V1_ScheduleRunsResponse]
    private var requestedProjectIDs: [String] = []
    private var requestedScheduleIDs: [String] = []
    private var requestedScheduleTokens: [String] = []
    private var requestedRunTokens: [String] = []
    private var requestedPageSizes: [Int32] = []

    init(schedules: [Dieter_V1_Schedule], runs: [Dieter_V1_ScheduleRun]) {
        var schedulesResponse = Dieter_V1_SchedulesResponse()
        schedulesResponse.schedules = schedules
        self.schedulesResponses = ["": schedulesResponse]
        var runsResponse = Dieter_V1_ScheduleRunsResponse()
        runsResponse.runs = runs
        self.runsResponses = ["": runsResponse]
    }

    init(schedulePages: [String: Dieter_V1_SchedulesResponse], runPages: [String: Dieter_V1_ScheduleRunsResponse]) {
        schedulesResponses = schedulePages
        runsResponses = runPages
    }

    func schedules(projectID: String, pageSize: Int32, pageToken: String) async throws -> Dieter_V1_SchedulesResponse {
        requestedProjectIDs.append(projectID)
        requestedScheduleTokens.append(pageToken)
        requestedPageSizes.append(pageSize)
        return schedulesResponses[pageToken] ?? Dieter_V1_SchedulesResponse()
    }

    func scheduleRuns(id: String, pageSize: Int32, pageToken: String) async throws -> Dieter_V1_ScheduleRunsResponse {
        requestedScheduleIDs.append(id)
        requestedRunTokens.append(pageToken)
        requestedPageSizes.append(pageSize)
        return runsResponses[pageToken] ?? Dieter_V1_ScheduleRunsResponse()
    }

    func requests() -> (
        projects: [String], schedules: [String], scheduleTokens: [String], runTokens: [String], pageSizes: [Int32]
    ) {
        (requestedProjectIDs, requestedScheduleIDs, requestedScheduleTokens, requestedRunTokens, requestedPageSizes)
    }
}

/// Schedules and their occurrence history load through the schedules surface.
struct ScheduleLoadingTests {
    @Test @MainActor func schedulesLoadThroughTheirOwnSurfaceWithoutWaitingForGlobalSync() async {
        var schedule = Dieter_V1_Schedule()
        schedule.id = "s_morning"
        schedule.projectID = "p_dieter"
        schedule.name = "Morning"
        var run = Dieter_V1_ScheduleRun()
        run.id = "sr_morning"
        run.scheduleID = schedule.id
        let rpc = ScheduleRPCStub(schedules: [schedule], runs: [run])
        let store = DieterStore(core: SchedulesCoreDouble.core(reader: rpc), liveEnvironment: false)
        store.selectedProjectID = schedule.projectID

        await store.loadSchedules()

        #expect(store.schedules.map(\.id) == [schedule.id])
        #expect(store.schedulesModel.selectedScheduleID == schedule.id)
        #expect(store.schedulesModel.scheduleRuns.map(\.id) == [run.id])
        #expect(store.schedulesModel.schedulesAreLoaded)
        #expect(!store.schedulesModel.schedulesLoading)
        #expect(!store.schedulesModel.scheduleRunsLoading)
        let requests = await rpc.requests()
        #expect(requests.projects == [schedule.projectID])
        #expect(requests.schedules == [schedule.id])
    }

    @Test @MainActor func schedulesAndOccurrenceHistoryAppendCursorPages() async {
        var morning = Dieter_V1_Schedule(); morning.id = "s_morning"; morning.projectID = "p_dieter";
        morning.name = "Morning"
        var nightly = Dieter_V1_Schedule(); nightly.id = "s_nightly"; nightly.projectID = morning.projectID;
        nightly.name = "Nightly"
        var firstSchedules = Dieter_V1_SchedulesResponse()
        firstSchedules.schedules = [morning]; firstSchedules.nextPageToken = "s-next"; firstSchedules.totalCount = 2
        var secondSchedules = Dieter_V1_SchedulesResponse()
        secondSchedules.schedules = [nightly]; secondSchedules.totalCount = 2

        var newest = Dieter_V1_ScheduleRun(); newest.id = "sr_new"; newest.scheduleID = morning.id
        var older = Dieter_V1_ScheduleRun(); older.id = "sr_old"; older.scheduleID = morning.id
        var firstRuns = Dieter_V1_ScheduleRunsResponse()
        firstRuns.runs = [newest]; firstRuns.nextPageToken = "r-next"
        var secondRuns = Dieter_V1_ScheduleRunsResponse(); secondRuns.runs = [older]

        let rpc = ScheduleRPCStub(
            schedulePages: ["": firstSchedules, "s-next": secondSchedules],
            runPages: ["": firstRuns, "r-next": secondRuns]
        )
        let store = DieterStore(core: SchedulesCoreDouble.core(reader: rpc), liveEnvironment: false)
        store.selectedProjectID = morning.projectID

        await store.loadSchedules()
        await store.schedulesModel.loadMoreSchedules()
        await store.schedulesModel.loadMoreScheduleRuns()

        #expect(store.schedules.map(\.id) == [morning.id, nightly.id])
        #expect(store.schedulesModel.schedulesTotalCount == 2)
        #expect(store.schedulesModel.schedulesNextPageToken.isEmpty)
        #expect(store.schedulesModel.scheduleRuns.map(\.id) == [newest.id, older.id])
        #expect(store.schedulesModel.scheduleRunsNextPageToken.isEmpty)
        let requests = await rpc.requests()
        #expect(requests.scheduleTokens == ["", "s-next"])
        #expect(requests.runTokens == ["", "r-next"])
        #expect(requests.pageSizes == [50, 50, 50, 50])
    }
}
