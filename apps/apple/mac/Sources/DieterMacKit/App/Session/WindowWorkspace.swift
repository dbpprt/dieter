import Observation

/// Dieter intentionally has one workspace window. Closing it leaves AppSession
/// and background synchronization alive; reopening restores this navigation.
@MainActor @Observable
final class WindowWorkspace {
    var section: AppSection = .board
    var kanbanPresentedAlongsideConversation = true
    var selectedProjectID = ""
    var selectedBoardID = ""
    var settingsSection: DieterSettingsSection = .general
    var newChatProjectID: String = ""
    var commandPalettePresented: Bool = false
    /// The floating sidebar card is hidden; the window controls float alone.
    var sidebarCollapsed: Bool = false
    var createConversationPresented: Bool = false
    /// The lane a lane's "+" asks New Card to start in; consumed by the sheet.
    var newCardLaneID: String = ""
    var createProjectPresented: Bool = false
    var createBoardPresented: Bool = false
    var renameProjectPresented: Bool = false
    var renameProjectTargetID: String = ""
    var renameBoardPresented: Bool = false
    var renameBoardTargetID: String = ""
    var projectContextPresented: Bool = false
    var labelsPresented: Bool = false
    var archivePolicyPresented: Bool = false
}
