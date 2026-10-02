import DieterAPI
import Foundation

extension DieterRPC {
    package func startExecution(_ request: Dieter_V1_StartExecutionRequest) async throws -> Dieter_V1_Execution {
        try await service.startExecution(request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }
    package func executions(projectID: String, cardID: String) async throws -> Dieter_V1_ExecutionsResponse {
        var request = Dieter_V1_ListExecutionsRequest()
        request.projectID = projectID; request.cardID = cardID
        return try await service.listExecutions(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func cancelExecution(id: String) async throws -> Dieter_V1_Execution {
        var request = Dieter_V1_ExecutionRef(); request.executionID = id
        return try await service.cancelExecution(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }
}
