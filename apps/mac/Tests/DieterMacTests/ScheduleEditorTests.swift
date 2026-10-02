import DieterAPI
import XCTest
@testable import DieterMac

final class ScheduleEditorTests: XCTestCase {
    func testScheduleEditorPresentationCarriesTheScheduleIntoTheSheet() {
        var draft = Dieter_V1_ScheduleDraft()
        draft.name = "Morning review"

        let presentation = ScheduleEditorPresentation(
            scheduleID: "sch_edit", draft: draft,
            context: .init(
                target: .init(endpointID: "machine", projectID: "project"), projectName: "Project", boards: [],
                selectedBoardID: "", harnessCatalog: .init()))

        XCTAssertEqual(presentation.scheduleID, "sch_edit")
        XCTAssertEqual(presentation.draft.name, "Morning review")
    }
}
