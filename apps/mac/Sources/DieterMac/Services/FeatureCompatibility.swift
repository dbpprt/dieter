import DieterAPI
import Foundation

// Navigation, legacy call sites, and smoke fixtures share these forwarding
// adapters during UI migration. State and tasks have one feature owner.
extension AppSession {
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
        set { replica.chats = newValue; refreshIslandActivityProjection() }
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
        set { replica.navigationCards = newValue; refreshIslandActivityProjection() }
    }
    var projectDirectory: [String: Dieter_V1_Project] {
        get { replica.projectDirectory }
        set { replica.projectDirectory = newValue }
    }
    var projectEndpointIDs: [String: String] {
        get { replica.projectEndpointIDs }
        set { replica.projectEndpointIDs = newValue }
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
        set { conversationModel.selectedCardID = newValue; bindComposer(); bindWorktree() }
    }
    var selectedChatID: String? {
        get { conversationModel.selectedChatID }
        set { conversationModel.selectedChatID = newValue; bindComposer(); bindWorktree() }
    }
    var conversation: Dieter_V1_ConversationSnapshot? {
        get { conversationModel.conversation }
        set { conversationModel.conversation = newValue }
    }
    var olderConversationMessages: [Dieter_V1_UiMessage] {
        get { conversationModel.olderConversationMessages }
        set { conversationModel.olderConversationMessages = newValue }
    }
    var conversationMessages: [Dieter_V1_UiMessage] {
        get { conversationModel.conversationMessages }
        set { conversationModel.conversationMessages = newValue }
    }
    var conversationPresentationRevision: Int {
        get { conversationModel.conversationPresentationRevision }
        set { conversationModel.conversationPresentationRevision = newValue }
    }
    var conversationHistoryStart: Int {
        get { conversationModel.conversationHistoryStart }
        set { conversationModel.conversationHistoryStart = newValue }
    }
    var conversationHistoryTotal: Int {
        get { conversationModel.conversationHistoryTotal }
        set { conversationModel.conversationHistoryTotal = newValue }
    }
    var conversationHistoryHasMore: Bool {
        get { conversationModel.conversationHistoryHasMore }
        set { conversationModel.conversationHistoryHasMore = newValue }
    }
    var conversationHistoryLoading: Bool {
        get { conversationModel.conversationHistoryLoading }
        set { conversationModel.conversationHistoryLoading = newValue }
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
    var conversationChangeset: Dieter_V1_Changeset? {
        get { worktreeChanges.conversationChangeset }
        set { worktreeChanges.conversationChangeset = newValue }
    }
    var conversationDiff: Dieter_V1_FileDiff? {
        get { worktreeChanges.conversationDiff }
        set { worktreeChanges.conversationDiff = newValue }
    }
    var conversationChangeComments: [Dieter_V1_ChangeComment] {
        get { worktreeChanges.conversationChangeComments }
        set { worktreeChanges.conversationChangeComments = newValue }
    }
    var conversationSCMCapabilities: Dieter_V1_SCMCapabilities? {
        get { worktreeChanges.conversationSCMCapabilities }
        set { worktreeChanges.conversationSCMCapabilities = newValue }
    }
    var gitOperation: Dieter_V1_GitOperation? {
        get { worktreeChanges.gitOperation }
        set { worktreeChanges.gitOperation = newValue }
    }
    var gitOperationLogs: [Dieter_V1_GitOperationLogEntry] {
        get { worktreeChanges.gitOperationLogs }
        set { worktreeChanges.gitOperationLogs = newValue }
    }
    var workspaceLoading: Bool {
        get { worktreeChanges.workspaceLoading }
        set { worktreeChanges.workspaceLoading = newValue }
    }
    var workspaceError: String? {
        get { worktreeChanges.workspaceError }
        set { worktreeChanges.workspaceError = newValue }
    }
    var selectedChangePath: String {
        get { worktreeChanges.selectedChangePath }
        set { worktreeChanges.selectedChangePath = newValue }
    }
    var selectedCommitSHA: String {
        get { worktreeChanges.selectedCommitSHA }
        set { worktreeChanges.selectedCommitSHA = newValue }
    }
    var workspaceToast: WorkspaceToast? {
        get { worktreeChanges.workspaceToast }
        set { worktreeChanges.workspaceToast = newValue }
    }
    var mergeFlowStep: WorkspaceMergeStep? {
        get { worktreeChanges.mergeFlowStep }
        set { worktreeChanges.mergeFlowStep = newValue }
    }
    var fileScopeCardID: String? {
        get { filesModel.fileScopeCardID }
        set { filesModel.fileScopeCardID = newValue }
    }
    var fileEditorSession: FileEditorSession {
        get { filesModel.fileEditorSession }
        set { filesModel.fileEditorSession = newValue }
    }
    var workspaceRequestGeneration: UInt64 {
        get { worktreeChanges.workspaceRequestGeneration }
        set { worktreeChanges.workspaceRequestGeneration = newValue }
    }
    var workspaceRefreshTask: Task<Void, Never>? {
        get { worktreeChanges.workspaceRefreshTask }
        set { worktreeChanges.workspaceRefreshTask = newValue }
    }
    var workspaceRefreshAgain: Bool {
        get { worktreeChanges.workspaceRefreshAgain }
        set { worktreeChanges.workspaceRefreshAgain = newValue }
    }
    var diffRequestGeneration: UInt64 {
        get { worktreeChanges.diffRequestGeneration }
        set { worktreeChanges.diffRequestGeneration = newValue }
    }
    var conversationDiffLoading: Bool {
        get { worktreeChanges.conversationDiffLoading }
        set { worktreeChanges.conversationDiffLoading = newValue }
    }
    var gitOperationSubmitting: Bool {
        get { worktreeChanges.gitOperationSubmitting }
        set { worktreeChanges.gitOperationSubmitting = newValue }
    }
    var gitOperationNeedsReconciliation: Bool {
        get { worktreeChanges.gitOperationNeedsReconciliation }
        set { worktreeChanges.gitOperationNeedsReconciliation = newValue }
    }
    var gitReconciliationGeneration: UInt64 {
        get { worktreeChanges.gitReconciliationGeneration }
        set { worktreeChanges.gitReconciliationGeneration = newValue }
    }
    var gitOperationSubmissionID: UUID? {
        get { worktreeChanges.gitOperationSubmissionID }
        set { worktreeChanges.gitOperationSubmissionID = newValue }
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
    var composerProvider: String {
        get { composer.draft.provider }
        set { composer.draft.provider = newValue }
    }
    var composerModel: String {
        get { composer.draft.model }
        set { composer.draft.model = newValue }
    }
    var composerEffort: String {
        get { composer.draft.effort }
        set { composer.draft.effort = newValue }
    }
    var composerProviderOptions: [String: String] {
        get { composer.draft.providerOptions }
        set { composer.draft.providerOptions = newValue }
    }
    var commentText: String {
        get { composer.draft.comment }
        set { composer.draft.comment = newValue }
    }
    var filesLoading: Bool {
        get { filesModel.filesLoading }
        set { filesModel.filesLoading = newValue }
    }
    var filesError: String? {
        get { filesModel.filesError }
        set { filesModel.filesError = newValue }
    }
    var fileLoading: Bool {
        get { filesModel.fileLoading }
        set { filesModel.fileLoading = newValue }
    }
    var fileError: String? {
        get { filesModel.fileError }
        set { filesModel.fileError = newValue }
    }
    var selectedFilePath: String {
        get { filesModel.selectedFilePath }
        set { filesModel.selectedFilePath = newValue }
    }
    var terminalRequestGeneration: UInt64 {
        get { terminalsModel.terminalRequestGeneration }
        set { terminalsModel.terminalRequestGeneration = newValue }
    }
    var terminalError: String? {
        get { terminalsModel.terminalError }
        set { terminalsModel.terminalError = newValue }
    }
    var schedulesError: String? {
        get { schedulesModel.schedulesError }
        set { schedulesModel.schedulesError = newValue }
    }
    var files: [Dieter_V1_FileEntry] {
        get { filesModel.files }
        set { filesModel.files = newValue }
    }
    var filePath: String {
        get { filesModel.filePath }
        set { filesModel.filePath = newValue }
    }
    var fileNavigation: ProjectFileNavigation {
        get { filesModel.fileNavigation }
        set { filesModel.fileNavigation = newValue }
    }
    var fileNavigationLoading: Bool {
        get { filesModel.fileNavigationLoading }
        set { filesModel.fileNavigationLoading = newValue }
    }
    var fileDocument: Dieter_V1_FileDocument? {
        get { filesModel.fileDocument }
        set { filesModel.fileDocument = newValue }
    }
    var showHiddenFiles: Bool {
        get { filesModel.showHiddenFiles }
        set { filesModel.showHiddenFiles = newValue }
    }
    var terminals: [Dieter_V1_Terminal] {
        get { terminalsModel.terminals }
        set { terminalsModel.terminals = newValue }
    }
    var selectedTerminalID: String? {
        get { terminalsModel.selectedTerminalID }
        set { terminalsModel.selectedTerminalID = newValue }
    }
    var terminalScreens: [String: TerminalScreenState] {
        get { terminalsModel.terminalScreens }
        set { terminalsModel.terminalScreens = newValue }
    }
    var terminalLoading: Bool {
        get { terminalsModel.terminalLoading }
        set { terminalsModel.terminalLoading = newValue }
    }
    var terminalStreamConnected: Bool {
        get { terminalsModel.terminalStreamConnected }
        set { terminalsModel.terminalStreamConnected = newValue }
    }
    var createTerminalPresented: Bool {
        get { terminalsModel.createTerminalPresented }
        set { terminalsModel.createTerminalPresented = newValue }
    }
    var schedules: [Dieter_V1_Schedule] {
        get { schedulesModel.schedules }
        set { schedulesModel.schedules = newValue }
    }
    var scheduleRuns: [Dieter_V1_ScheduleRun] {
        get { schedulesModel.scheduleRuns }
        set { schedulesModel.scheduleRuns = newValue }
    }
    var selectedScheduleID: String? {
        get { schedulesModel.selectedScheduleID }
        set { schedulesModel.selectedScheduleID = newValue }
    }
    var schedulesLoading: Bool {
        get { schedulesModel.schedulesLoading }
        set { schedulesModel.schedulesLoading = newValue }
    }
    var schedulesLoadingMore: Bool {
        get { schedulesModel.schedulesLoadingMore }
        set { schedulesModel.schedulesLoadingMore = newValue }
    }
    var scheduleRunsLoading: Bool {
        get { schedulesModel.scheduleRunsLoading }
        set { schedulesModel.scheduleRunsLoading = newValue }
    }
    var scheduleRunsLoadingMore: Bool {
        get { schedulesModel.scheduleRunsLoadingMore }
        set { schedulesModel.scheduleRunsLoadingMore = newValue }
    }
    var schedulesTotalCount: Int {
        get { schedulesModel.schedulesTotalCount }
        set { schedulesModel.schedulesTotalCount = newValue }
    }
    var schedulesNextPageToken: String {
        get { schedulesModel.schedulesNextPageToken }
        set { schedulesModel.schedulesNextPageToken = newValue }
    }
    var scheduleRunsNextPageToken: String {
        get { schedulesModel.scheduleRunsNextPageToken }
        set { schedulesModel.scheduleRunsNextPageToken = newValue }
    }
    var schedulesLoadedProjectID: String {
        get { schedulesModel.schedulesLoadedProjectID }
        set { schedulesModel.schedulesLoadedProjectID = newValue }
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
    var conversationTask: Task<Void, Never>? {
        get { conversationModel.conversationTask }
        set { conversationModel.conversationTask = newValue }
    }
    var gitOperationTask: Task<Void, Never>? {
        get { worktreeChanges.gitOperationTask }
        set { worktreeChanges.gitOperationTask = newValue }
    }
    var workspaceToastTask: Task<Void, Never>? {
        get { worktreeChanges.workspaceToastTask }
        set { worktreeChanges.workspaceToastTask = newValue }
    }
    var terminalWatchTask: Task<Void, Never>? {
        get { terminalsModel.terminalWatchTask }
        set { terminalsModel.terminalWatchTask = newValue }
    }
    var conversationHistoryRequestID: UUID? {
        get { conversationModel.conversationHistoryRequestID }
        set { conversationModel.conversationHistoryRequestID = newValue }
    }
    var terminalSequences: [String: UInt64] {
        get { terminalsModel.terminalSequences }
        set { terminalsModel.terminalSequences = newValue }
    }
    var schedulesLoadedEndpointID: String {
        get { schedulesModel.schedulesLoadedEndpointID }
        set { schedulesModel.schedulesLoadedEndpointID = newValue }
    }
}
