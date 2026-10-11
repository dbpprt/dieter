import Testing
@testable import DieterMacKit

/// Sidebar width and project drag payloads.
struct SidebarTests {
    @Test func sidebarWidthIsClampedToItsSupportedRange() {
        #expect(SidebarSizing.clamped(180) == SidebarSizing.minimumWidth)
        #expect(SidebarSizing.clamped(300) == 300)
        #expect(SidebarSizing.clamped(500) == SidebarSizing.maximumWidth)
    }

    @Test func sidebarProjectDragPayloadRejectsOtherStringDrops() {
        let payload = SidebarProjectDragPayload(projectID: "p_one")
        #expect(SidebarProjectDragPayload(payload.encoded) == payload)
        #expect(SidebarProjectDragPayload("not-a-sidebar-project") == nil)
        #expect(SidebarProjectDragPayload("dieter:sidebar-project:") == nil)
    }
}
