import Testing

@testable import DieterMac

@Test func chatPaneWidthDependsOnlyOnStoredAndWorkspaceWidths() {
    #expect(ChatPaneSizing.resolvedWidth(320, workspaceWidth: 1_200) == 320)
    #expect(ChatPaneSizing.resolvedWidth(1_000, workspaceWidth: 1_200) == 340)
    #expect(ChatPaneSizing.resolvedWidth(100, workspaceWidth: 1_200) == 285)
    #expect(ChatPaneSizing.resolvedWidth(320, workspaceWidth: 640) == 313)
    #expect(ChatPaneSizing.resolvedWidth(320, workspaceWidth: 500) == 173)
    #expect(ChatPaneSizing.dividerHitWidth > ChatPaneSizing.dividerLineWidth)
}
