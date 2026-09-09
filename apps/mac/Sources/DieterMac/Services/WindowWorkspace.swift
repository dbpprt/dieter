import Observation

/// Dieter intentionally has one workspace window. Closing it leaves AppSession
/// and background synchronization alive; reopening restores this navigation.
@MainActor @Observable
final class WindowWorkspace {
    var section: AppSection = .board
    var selectedProjectID = ""
    var selectedBoardID = ""
    var settingsSection: DieterSettingsSection = .general
    var newChatProjectID: String = ""
    var commandPalettePresented: Bool = false
    var createConversationPresented: Bool = false
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
