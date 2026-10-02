import DieterCore
import Foundation
import GRPCCore
import Testing

@Test func localConversationIDsNeverQualifyForServerFetch() {
    #expect(!DieterConversationID.isServerBacked("local_chat"))
    #expect(DieterConversationID.isServerBacked("c_server"))
}

@Test func rpcErrorsExposeStatusAndMessage() {
    let error = RPCError(code: .notFound, message: "card c_missing was not found")

    #expect(DieterRPCFailure.isPermanent(error))
    #expect(DieterRPCFailure.message(for: error) == "gRPC notFound: card c_missing was not found")
    #expect(!DieterRPCFailure.message(for: error).contains("RPCError error 1"))
    #expect(!DieterRPCFailure.isPermanent(RPCError(code: .aborted, message: "turn teardown in progress")))
    #expect(DieterRPCFailure.isPermanent(RPCError(code: .failedPrecondition, message: "invalid state")))
}

@Test func rpcStatusesClassifyTransientFailures() {
    #expect(DieterRPCFailure.isTransient(RPCError(code: .unavailable, message: "stream unexpectedly closed")))
    #expect(DieterRPCFailure.isTransient(RPCError(code: .deadlineExceeded, message: "timed out")))
    #expect(!DieterRPCFailure.isTransient(RPCError(code: .notFound, message: "board missing")))
}
