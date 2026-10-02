import Foundation
import GRPCCore

package enum DieterConversationID {
    package static func isServerBacked(_ id: String) -> Bool {
        !id.hasPrefix("local_")
    }
}

package enum DieterRPCFailure {
    package static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? RPCError)?.code == .cancelled
    }

    package static func isTransient(_ error: Error) -> Bool {
        if let rpcError = error as? RPCError {
            if [.cancelled, .deadlineExceeded, .unavailable].contains(rpcError.code) {
                return true
            }
            if isPermanent(rpcError) { return false }
            return rpcError.cause.map(isTransient) ?? false
        }
        if let runtimeError = error as? RuntimeError {
            if runtimeError.code == .clientIsStopped || runtimeError.code == .transportError {
                return true
            }
            return runtimeError.cause.map(isTransient) ?? false
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return [
                POSIXErrorCode.EPIPE,
                .ECONNABORTED,
                .ECONNRESET,
                .ENOTCONN,
                .ETIMEDOUT,
                .ENETDOWN,
                .ENETUNREACH,
                .EHOSTDOWN,
                .EHOSTUNREACH,
                .ECONNREFUSED,
            ].contains { Int($0.rawValue) == nsError.code }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isTransient(underlying)
        }
        return false
    }

    package static func isAuthenticationFailure(_ error: Error) -> Bool {
        (error as? RPCError)?.code == .unauthenticated
    }

    package static func isPermanent(_ error: Error) -> Bool {
        guard let rpcError = error as? RPCError else { return false }
        return [.notFound, .invalidArgument, .permissionDenied, .failedPrecondition].contains(rpcError.code)
    }

    /// Recognize both admission checks and filesystem failures, including errors
    /// restored from the durable outbox. Other resource limits are not disk pressure.
    package static func isInsufficientStorage(_ message: String?) -> Bool {
        guard let message = message?.lowercased() else { return false }
        return [
            "insufficient free disk space", "no space left on device", "disk quota exceeded", "disc quota exceeded",
        ]
        .contains { message.contains($0) }
    }

    package static func message(for error: Error) -> String {
        guard let rpcError = error as? RPCError else { return error.localizedDescription }
        let detail = scrub(rpcError.message)
        return detail.isEmpty ? "gRPC \(rpcError.code)" : "gRPC \(rpcError.code): \(detail)"
    }

    package static func scrub(_ value: String) -> String {
        var value =
            value
            .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?i)bearer\\s+[^ ]+", with: "Bearer [redacted]", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > 500 {
            value = String(value.prefix(500)) + "…"
        }
        return value
    }
}
