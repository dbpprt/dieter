import DieterAPI
import Foundation

// The daemon calls behind the feature doubles (`FilesCoreDouble`,
// `TerminalsCoreDouble`, `SchedulesCoreDouble`): each double serves the shared
// core's surface over a test fixture that implements one of these.

protocol FilesRPC: AnyObject, Sendable {
    func listFiles(_ request: Dieter_V1_ListFilesRequest) async throws -> Dieter_V1_FileList
    func readFile(_ request: Dieter_V1_ReadFileRequest) async throws -> Dieter_V1_FileDocument
    func saveFile(_ request: Dieter_V1_SaveFileRequest) async throws -> Dieter_V1_FileDocument
    func createFile(_ request: Dieter_V1_CreateFileRequest) async throws -> Dieter_V1_FileEntry
    func deleteFile(_ request: Dieter_V1_DeleteFileRequest) async throws
    func moveFile(_ request: Dieter_V1_MoveFileRequest) async throws -> Dieter_V1_MoveFileResponse
}

protocol ScheduleCommandsRPC: AnyObject, Sendable {
    func createSchedule(_ request: Dieter_V1_SaveScheduleRequest) async throws -> Dieter_V1_Schedule
    func updateSchedule(_ request: Dieter_V1_SaveScheduleRequest) async throws -> Dieter_V1_Schedule
    func deleteSchedule(id: String) async throws
    func runSchedule(id: String) async throws -> Dieter_V1_ScheduleRun
    func setScheduleEnabled(id: String, enabled: Bool) async throws -> Dieter_V1_Schedule
    func previewSchedule(_ request: Dieter_V1_PreviewScheduleRequest) async throws -> Dieter_V1_SchedulePreview
}

protocol TerminalInputRPC: AnyObject, Sendable {
    func writeTerminal(id: String, data: Data) async throws -> Dieter_V1_Terminal
}

protocol TerminalsRPC: TerminalInputRPC {
    func terminals(projectID: String, cardID: String) async throws -> Dieter_V1_TerminalsResponse
    func createTerminal(_ request: Dieter_V1_CreateTerminalRequest) async throws -> Dieter_V1_Terminal
    func watchTerminal(id: String, after: UInt64, receive: @escaping @Sendable (Dieter_V1_TerminalFrame) async -> Void)
        async throws
    func resizeTerminal(id: String, columns: Int, rows: Int) async throws -> Dieter_V1_Terminal
    func renameTerminal(id: String, name: String) async throws -> Dieter_V1_Terminal
    func closeTerminal(id: String) async throws
}

protocol DieterScheduleRPC: AnyObject, Sendable {
    func schedules(projectID: String, pageSize: Int32, pageToken: String) async throws -> Dieter_V1_SchedulesResponse
    func scheduleRuns(id: String, pageSize: Int32, pageToken: String) async throws -> Dieter_V1_ScheduleRunsResponse
}
