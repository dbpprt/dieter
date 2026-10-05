import DieterAPI
import Foundation

// Views and the store read window, replica, and feature state through these
// forwarders; each value has one owner (the window, the replica, or a feature
// model), and a forwarder's setter keeps dependent bindings current.
extension AppSession {
    var kanbanPresentedAlongsideConversation: Bool {
        get { window.kanbanPresentedAlongsideConversation }
        set { window.kanbanPresentedAlongsideConversation = newValue }
    }

    var settingsSection: DieterSettingsSection {
        get { window.settingsSection }
        set { window.settingsSection = newValue }
    }
    var state: Dieter_V1_State {
        get { replica.state }
        set { replica.state = newValue; refreshReplicaPresentation() }
    }
    var chats: [Dieter_V1_Card] {
        get { replica.chats }
        set { replica.chats = newValue }
    }
    var chatProjects: [Dieter_V1_Project] {
        get { replica.chatProjects }
        set { replica.chatProjects = newValue }
    }
    var navigationBoards: [String: [Dieter_V1_Board]] {
        get { replica.navigationBoards }
        set { replica.navigationBoards = newValue }
    }
    var navigationCards: [String: [Dieter_V1_Card]] {
        get { replica.navigationCards }
        set { replica.navigationCards = newValue }
    }
    var projectDirectory: [String: Dieter_V1_Project] {
        get { replica.projectDirectory }
        set { replica.projectDirectory = newValue }
    }
    var projectHosts: [String: String] {
        get { replica.projectHosts }
        set { replica.projectHosts = newValue }
    }
    var selectedProjectID: String {
        get { window.selectedProjectID }
        set {
            guard window.selectedProjectID != newValue else { return }; window.selectedProjectID = newValue;
            resetFileSurface(); bindSchedules(); bindConversation(); bindWorktree(); bindTerminals()
        }
    }
    var selectedBoardID: String {
        get { window.selectedBoardID }
        set {
            guard window.selectedBoardID != newValue else { return }; window.selectedBoardID = newValue;
            refreshBoardProjection()
        }
    }
    var selectedCardID: String? {
        get { conversationModel.selectedCardID }
        set {
            guard conversationModel.selectedCardID != newValue else { return }
            conversationModel.selectedCardID = newValue
            bindComposer()
            bindWorktree()
        }
    }
    var selectedChatID: String? {
        get { conversationModel.selectedChatID }
        set {
            guard conversationModel.selectedChatID != newValue else { return }
            conversationModel.selectedChatID = newValue
            bindComposer()
            bindWorktree()
        }
    }
    var conversation: Dieter_V1_ConversationSnapshot? {
        get { conversationModel.conversation }
        set { conversationModel.conversation = newValue }
    }
    var conversationMessages: [Dieter_V1_UiMessage] {
        get { conversationModel.conversationMessages }
        set { conversationModel.conversationMessages = newValue }
    }
    var conversationHistoryHasMore: Bool {
        get { conversationModel.conversationHistoryHasMore }
        set { conversationModel.conversationHistoryHasMore = newValue }
    }
    var selectedDetail: Dieter_V1_CardDetail? {
        get { conversationModel.selectedDetail }
        set { conversationModel.selectedDetail = newValue; bindWorktree() }
    }
    var conversationSelectionGeneration: UInt64 {
        get { conversationModel.conversationSelectionGeneration }
        set { conversationModel.conversationSelectionGeneration = newValue }
    }
    var conversationError: String? {
        get { conversationModel.conversationError }
        set { conversationModel.conversationError = newValue }
    }
    var conversationLoading: Bool {
        get { conversationModel.conversationLoading }
        set { conversationModel.conversationLoading = newValue }
    }
    var conversationSyncing: Bool {
        get { conversationModel.conversationSyncing }
        set { conversationModel.conversationSyncing = newValue }
    }
    var conversationLastRefreshedAt: Date? {
        get { conversationModel.conversationLastRefreshedAt }
        set { conversationModel.conversationLastRefreshedAt = newValue }
    }
    var conversationWorkspace: Dieter_V1_Workspace? {
        get { worktreeChanges.conversationWorkspace }
        set { worktreeChanges.conversationWorkspace = newValue }
    }
    var gitOperation: Dieter_V1_GitOperation? {
        get { worktreeChanges.gitOperation }
        set { worktreeChanges.gitOperation = newValue }
    }
    var workspaceError: String? {
        get { worktreeChanges.workspaceError }
        set { worktreeChanges.workspaceError = newValue }
    }
    var workspaceToast: WorkspaceToast? {
        get { worktreeChanges.workspaceToast }
        set { worktreeChanges.workspaceToast = newValue }
    }
    var fileScopeCardID: String? {
        get { filesModel.fileScopeCardID }
        set { filesModel.fileScopeCardID = newValue }
    }
    var terminalScopeCardID: String? {
        get { terminalsModel.terminalScopeCardID }
        set { terminalsModel.terminalScopeCardID = newValue; bindTerminals() }
    }
    var composerText: String {
        get { composer.draft.text }
        set { composer.draft.text = newValue }
    }
    var composerAttachments: [Dieter_V1_MessagePart] {
        get { composer.draft.attachments }
        set { composer.draft.attachments = newValue }
    }
    var filesError: String? {
        get { filesModel.filesError }
        set { filesModel.filesError = newValue }
    }
    var schedulesError: String? {
        get { schedulesModel.schedulesError }
        set { schedulesModel.schedulesError = newValue }
    }
    var fileDocument: Dieter_V1_FileDocument? {
        get { filesModel.fileDocument }
        set { filesModel.fileDocument = newValue }
    }
    var schedules: [Dieter_V1_Schedule] {
        get { schedulesModel.schedules }
        set { schedulesModel.schedules = newValue }
    }
    var newChatProjectID: String {
        get { window.newChatProjectID }
        set { window.newChatProjectID = newValue }
    }
    var commandPalettePresented: Bool {
        get { window.commandPalettePresented }
        set { window.commandPalettePresented = newValue }
    }
    var createConversationPresented: Bool {
        get { window.createConversationPresented }
        set { window.createConversationPresented = newValue }
    }
    var createProjectPresented: Bool {
        get { window.createProjectPresented }
        set { window.createProjectPresented = newValue }
    }
    var createBoardPresented: Bool {
        get { window.createBoardPresented }
        set { window.createBoardPresented = newValue }
    }
    var renameProjectPresented: Bool {
        get { window.renameProjectPresented }
        set { window.renameProjectPresented = newValue }
    }
    var renameProjectTargetID: String {
        get { window.renameProjectTargetID }
        set { window.renameProjectTargetID = newValue }
    }
    var renameBoardPresented: Bool {
        get { window.renameBoardPresented }
        set { window.renameBoardPresented = newValue }
    }
    var renameBoardTargetID: String {
        get { window.renameBoardTargetID }
        set { window.renameBoardTargetID = newValue }
    }
    var projectContextPresented: Bool {
        get { window.projectContextPresented }
        set { window.projectContextPresented = newValue }
    }
    var labelsPresented: Bool {
        get { window.labelsPresented }
        set { window.labelsPresented = newValue }
    }
    var archivePolicyPresented: Bool {
        get { window.archivePolicyPresented }
        set { window.archivePolicyPresented = newValue }
    }
}
