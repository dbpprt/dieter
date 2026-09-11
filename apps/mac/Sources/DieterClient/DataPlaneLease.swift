import DieterCore

/// A temporary borrower returns a transport without stopping other app work.
@MainActor
package final class DataPlaneLease {
    package let rpc: DieterRPC
    package let connection: MachineConnectionStatus
    private var onRelease: (@MainActor (Bool) -> Void)?

    package init(plane: DataPlaneConnection, release: @escaping @MainActor (Bool) -> Void) {
        rpc = plane.rpc; connection = plane.connection; onRelease = release
    }

    package func release(reusable: Bool = true) {
        let action = onRelease; onRelease = nil; action?(reusable)
    }
}
