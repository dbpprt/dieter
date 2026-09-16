import Foundation
import GRPCCore

/// RPCError's Foundation description omits the server's useful explanation.
/// Preserve it for authentication, admission, and file-conflict failures.
enum IOSUserError {
    static func message(_ error: any Error) -> String {
        guard let rpc = error as? RPCError else { return error.localizedDescription }
        let message = rpc.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { return message }
        switch rpc.code {
        case .unauthenticated: return "Authentication required. Sign in to this gateway again."
        case .permissionDenied: return "This account does not have access to the requested machine."
        case .unavailable: return "The machine or gateway is unavailable. Check the connection and try again."
        case .deadlineExceeded: return "The request timed out. Check the connection and try again."
        default: return "The request failed (\(rpc.code))."
        }
    }
}
