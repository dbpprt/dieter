import DieterAPI
import DieterCore
import Foundation

extension DieterRPC: ProcessesRPC {
    package func startExecution(_ request: Dieter_V1_StartExecutionRequest) async throws -> Dieter_V1_Execution {
        try await service.startExecution(request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }
    package func executions(projectID: String, cardID: String) async throws -> Dieter_V1_ExecutionsResponse {
        var request = Dieter_V1_ListExecutionsRequest()
        request.projectID = projectID; request.cardID = cardID
        return try await service.listExecutions(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func watchExecution(
        id: String, after: UInt64, receive: @escaping @Sendable (Dieter_V1_ExecutionEvent) async -> Void
    ) async throws {
        var request = Dieter_V1_WatchExecutionRequest()
        request.executionID = id; request.afterSequence = after; request.heartbeatMs = 15_000
        try await service.watchExecution(request: .init(message: request), options: Self.attachmentCallOptions()) {
            response in
            for try await event in response.messages {
                try Task.checkCancellation()
                await receive(event)
            }
        }
    }

    package func cancelExecution(id: String) async throws -> Dieter_V1_Execution {
        var request = Dieter_V1_ExecutionRef(); request.executionID = id
        return try await service.cancelExecution(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }
}
