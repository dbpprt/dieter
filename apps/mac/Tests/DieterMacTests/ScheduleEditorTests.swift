import DieterAPI
import XCTest
@testable import DieterMac

final class ScheduleEditorTests: XCTestCase {
    func testScheduleEditorPresentationCarriesTheScheduleIntoTheSheet() {
        var schedule = Dieter_V1_Schedule()
        schedule.id = "sch_edit"

        let presentation = ScheduleEditorPresentation(schedule: schedule)

        XCTAssertEqual(presentation.schedule?.id, schedule.id)
    }

    func testScheduleEditorLoadsEveryEditableScheduleField() {
        var schedule = Dieter_V1_Schedule()
        schedule.projectID = "project"
        schedule.boardID = "board"
        schedule.name = "Morning review"
        schedule.description_p = "Review the project"
        schedule.cron = "15 8 * * 1"
        schedule.timezone = "Europe/Berlin"
        schedule.enabled = false
        schedule.action = "run"
        schedule.titleTemplate = "Review · {{date}}"
        schedule.promptTemplate = "Review {{project}}"
        schedule.provider = "codex"
        schedule.model = "gpt-5.6-sol"
        schedule.effort = "high"
        schedule.labelIds = ["label_mac"]
        schedule.openCardPolicy = "always"
        schedule.misfirePolicy = "latest"
        schedule.busyPolicy = "skip"
        schedule.providerOptions = ["personality": "pragmatic"]

        let draft = ScheduleEditorDraft.make(from: schedule)
        var expected = Dieter_V1_ScheduleDraft()
        expected.projectID = schedule.projectID
        expected.boardID = schedule.boardID
        expected.name = schedule.name
        expected.description_p = schedule.description_p
        expected.cron = schedule.cron
        expected.timezone = schedule.timezone
        expected.enabled = schedule.enabled
        expected.action = schedule.action
        expected.titleTemplate = schedule.titleTemplate
        expected.promptTemplate = schedule.promptTemplate
        expected.provider = schedule.provider
        expected.model = schedule.model
        expected.effort = schedule.effort
        expected.labelIds = schedule.labelIds
        expected.openCardPolicy = schedule.openCardPolicy
        expected.misfirePolicy = schedule.misfirePolicy
        expected.busyPolicy = schedule.busyPolicy
        expected.providerOptions = schedule.providerOptions
        expected.workspaceMode = "project"

        XCTAssertEqual(draft, expected)
    }

    func testScheduleEditorPreviewDebounceStopsWhenCancelled() async {
        let debounce = Task { await ScheduleEditorPreviewDebounce.wait() }
        await Task.yield()
        debounce.cancel()
        let completed = await debounce.value

        XCTAssertFalse(completed)
    }
}
