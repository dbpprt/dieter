import Testing

@testable import DieterMac

@Test func chatPaneWidthDependsOnlyOnStoredAndWorkspaceWidths() {
    #expect(ChatPaneSizing.resolvedWidth(320, workspaceWidth: 1_200) == 320)
    #expect(ChatPaneSizing.resolvedWidth(1_000, workspaceWidth: 1_200) == 340)
    #expect(ChatPaneSizing.resolvedWidth(100, workspaceWidth: 1_200) == 285)
    // The detail keeps a 327-point conversation inside its floating panel.
    #expect(ChatPaneSizing.minimumDetailWidth == 347)
    #expect(ChatPaneSizing.resolvedWidth(320, workspaceWidth: 640) == 293)
    #expect(ChatPaneSizing.resolvedWidth(320, workspaceWidth: 500) == 153)
    #expect(ChatPaneSizing.dividerHitWidth > ChatPaneSizing.dividerLineWidth)
}
