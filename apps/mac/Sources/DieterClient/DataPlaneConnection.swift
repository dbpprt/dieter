import DieterCore
import Foundation

package struct DataPlaneConnection: Sendable {
    package init(
        rpc: DieterRPC, task: Task<Void, Never>, connection: MachineConnectionStatus, directTokenExpiresAt: String?
    ) {
        self.rpc = rpc; self.task = task; self.connection = connection; self.directTokenExpiresAt = directTokenExpiresAt
    }
    package func shutdown() { task.cancel(); rpc.shutdown() }
    package let rpc: DieterRPC
    package let task: Task<Void, Never>
    package let connection: MachineConnectionStatus
    package let directTokenExpiresAt: String?
}
