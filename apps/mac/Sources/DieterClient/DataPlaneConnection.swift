import DieterCore
import Foundation

package struct DataPlaneConnection: Sendable {
    package init(
        rpc: DieterRPC,
        task: Task<Void, Never>,
        connection: MachineConnectionStatus,
        directTokenExpiresAt: String?,
        directCredential: DirectAccessCredential? = nil,
        credentialRefreshTask: Task<Void, Never>? = nil
    ) {
        self.rpc = rpc
        self.task = task
        self.connection = connection
        self.directTokenExpiresAt = directTokenExpiresAt
        self.directCredential = directCredential
        self.credentialRefreshTask = credentialRefreshTask
    }
    package func shutdown() { credentialRefreshTask?.cancel(); task.cancel(); rpc.shutdown() }
    package let rpc: DieterRPC
    package let task: Task<Void, Never>
    package let connection: MachineConnectionStatus
    package let directTokenExpiresAt: String?
    package let directCredential: DirectAccessCredential?
    package let credentialRefreshTask: Task<Void, Never>?
}
