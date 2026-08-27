import DieterAPI
import Testing
@testable import DieterMac

@Test func scheduleEditorPresentationCarriesTheScheduleIntoTheSheet() {
    var schedule = Dieter_V1_Schedule()
    schedule.id = "sch_edit"

    let presentation = ScheduleEditorPresentation(schedule: schedule)

    #expect(presentation.schedule?.id == schedule.id)
}

@Test func scheduleEditorLoadsEveryEditableScheduleField() {
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

    #expect(draft.projectID == schedule.projectID)
    #expect(draft.boardID == schedule.boardID)
    #expect(draft.name == schedule.name)
    #expect(draft.description_p == schedule.description_p)
    #expect(draft.cron == schedule.cron)
    #expect(draft.timezone == schedule.timezone)
    #expect(draft.enabled == schedule.enabled)
    #expect(draft.action == schedule.action)
    #expect(draft.titleTemplate == schedule.titleTemplate)
    #expect(draft.promptTemplate == schedule.promptTemplate)
    #expect(draft.provider == schedule.provider)
    #expect(draft.model == schedule.model)
    #expect(draft.effort == schedule.effort)
    #expect(draft.labelIds == schedule.labelIds)
    #expect(draft.openCardPolicy == schedule.openCardPolicy)
    #expect(draft.misfirePolicy == schedule.misfirePolicy)
    #expect(draft.busyPolicy == schedule.busyPolicy)
    #expect(draft.providerOptions == schedule.providerOptions)
}

@Test func scheduleEditorPreviewDebounceStopsWhenCancelled() async {
    let debounce = Task { await ScheduleEditorPreviewDebounce.wait() }
    await Task.yield()
    debounce.cancel()

    #expect(await debounce.value == false)
}
