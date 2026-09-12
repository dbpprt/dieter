import DieterAPI
import Foundation

package protocol OutboxRPC: AnyObject, Sendable {
    func createCard(_ request: Dieter_V1_CreateConversationRequest) async throws -> Dieter_V1_Card
    func createChat(_ request: Dieter_V1_CreateConversationRequest) async throws -> Dieter_V1_Card
    func sendMessage(_ request: Dieter_V1_SendMessageRequest) async throws -> Dieter_V1_SendMessageResponse
}

package protocol FilesRPC: AnyObject, Sendable {
    func listFiles(_ request: Dieter_V1_ListFilesRequest) async throws -> Dieter_V1_FileList
    func readFile(_ request: Dieter_V1_ReadFileRequest) async throws -> Dieter_V1_FileDocument
    func saveFile(_ request: Dieter_V1_SaveFileRequest) async throws -> Dieter_V1_FileDocument
    func createFile(_ request: Dieter_V1_CreateFileRequest) async throws -> Dieter_V1_FileEntry
    func deleteFile(_ request: Dieter_V1_DeleteFileRequest) async throws
    func moveFile(_ request: Dieter_V1_MoveFileRequest) async throws -> Dieter_V1_MoveFileResponse
}

package protocol ConversationRPC: AnyObject, Sendable {
    func conversation(cardID: String, limit: Int32, before: Int32?) async throws -> Dieter_V1_ConversationSnapshot
    func watchConversation(
        cardID: String, after: Int64, receive: @escaping @Sendable (Dieter_V1_ConversationUpdate) async -> Void)
        async throws
}

package protocol WorktreeRPC: AnyObject, Sendable {
    func workspace(cardID: String) async throws -> Dieter_V1_Workspace
    func changeset(cardID: String) async throws -> Dieter_V1_Changeset
    func fileDiff(_ request: Dieter_V1_GetDiffRequest) async throws -> Dieter_V1_FileDiff
    func commitDiff(_ request: Dieter_V1_GetDiffRequest) async throws -> Dieter_V1_FileDiff
    func changeComments(cardID: String, revision: String) async throws -> Dieter_V1_ChangeCommentsResponse
    func scmCapabilities(cardID: String) async throws -> Dieter_V1_SCMCapabilities
    func addChangeComment(_ request: Dieter_V1_AddChangeCommentRequest) async throws -> Dieter_V1_ChangeComment
    func updateConversationWorkspace(_ request: Dieter_V1_UpdateConversationWorkspaceRequest) async throws
        -> Dieter_V1_Card
    func startGitOperation(_ request: Dieter_V1_StartGitOperationRequest) async throws -> Dieter_V1_GitOperation
    func gitOperation(id: String) async throws -> Dieter_V1_GitOperation
    func cancelGitOperation(id: String) async throws -> Dieter_V1_GitOperation
    func watchGitOperation(
        id: String, after: UInt64, receive: @escaping @Sendable (Dieter_V1_GitOperationFrame) async -> Void)
        async throws
    func moveCard(_ request: Dieter_V1_MoveCardRequest) async throws -> Dieter_V1_Card
}

package protocol ScheduleCommandsRPC: AnyObject, Sendable {
    func createSchedule(_ request: Dieter_V1_SaveScheduleRequest) async throws -> Dieter_V1_Schedule
    func updateSchedule(_ request: Dieter_V1_SaveScheduleRequest) async throws -> Dieter_V1_Schedule
    func deleteSchedule(id: String) async throws
    func runSchedule(id: String) async throws -> Dieter_V1_ScheduleRun
    func setScheduleEnabled(id: String, enabled: Bool) async throws -> Dieter_V1_Schedule
    func previewSchedule(_ request: Dieter_V1_PreviewScheduleRequest) async throws -> Dieter_V1_SchedulePreview
}

package protocol TerminalInputRPC: AnyObject, Sendable {
    func writeTerminal(id: String, data: Data) async throws -> Dieter_V1_Terminal
}

package protocol ProcessesRPC: AnyObject, Sendable {
    func executions(projectID: String, cardID: String) async throws -> Dieter_V1_ExecutionsResponse
    func watchExecution(
        id: String, after: UInt64, receive: @escaping @Sendable (Dieter_V1_ExecutionEvent) async -> Void) async throws
    func cancelExecution(id: String) async throws -> Dieter_V1_Execution
}

package protocol TerminalsRPC: TerminalInputRPC {
    func terminals(projectID: String, cardID: String) async throws -> Dieter_V1_TerminalsResponse
    func createTerminal(_ request: Dieter_V1_CreateTerminalRequest) async throws -> Dieter_V1_Terminal
    func watchTerminal(id: String, after: UInt64, receive: @escaping @Sendable (Dieter_V1_TerminalFrame) async -> Void)
        async throws
    func resizeTerminal(id: String, columns: Int, rows: Int) async throws -> Dieter_V1_Terminal
    func renameTerminal(id: String, name: String) async throws -> Dieter_V1_Terminal
    func closeTerminal(id: String) async throws
}

package protocol ProjectChangesRPC: AnyObject, Sendable {
    func changeset(projectID: String) async throws -> Dieter_V1_Changeset
    func fileDiff(_ request: Dieter_V1_GetDiffRequest) async throws -> Dieter_V1_FileDiff
    func startGitOperation(_ request: Dieter_V1_StartGitOperationRequest) async throws -> Dieter_V1_GitOperation
    func gitOperation(id: String) async throws -> Dieter_V1_GitOperation
}

package protocol ScreenSignalingRPC: AnyObject, Sendable {
    func remoteDesktopSettings() async throws -> Dieter_V1_RemoteDesktopSettings
    func remoteDesktopCapabilities() async throws -> Dieter_V1_RemoteDesktopCapabilities
    func updateRemoteDesktopSettings(enabled: Bool, controlEnabled: Bool) async throws
        -> Dieter_V1_RemoteDesktopSettings
    func startRemoteDesktop(
        _ request: Dieter_V1_StartRemoteDesktopRequest,
        receive: @escaping @Sendable (Dieter_V1_RemoteDesktopSignal) async throws -> Void) async throws
    func sendRemoteDesktopSignal(_ signal: Dieter_V1_RemoteDesktopSignal) async throws
    func closeRemoteDesktop(sessionID: String) async throws
    func shutdown()
}

package protocol DieterScheduleRPC: AnyObject, Sendable {
    func schedules(projectID: String, pageSize: Int32, pageToken: String) async throws -> Dieter_V1_SchedulesResponse
    func scheduleRuns(id: String, pageSize: Int32, pageToken: String) async throws -> Dieter_V1_ScheduleRunsResponse
}

package protocol DieterChatPinRPC: Sendable {
    func pinChat(_ request: Dieter_V1_PinChatRequest) async throws -> Dieter_V1_Card
}

package protocol DieterCardStartRPC: Sendable {
    func startCard(_ request: Dieter_V1_StartCardRequest) async throws -> Dieter_V1_StartCardResponse
}
