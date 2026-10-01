import DieterAPI
import DieterCore
import Foundation
import SharedCore

/// The shared core's terminal surfaces (`Terminals.kt`) over a `TerminalsRPC`
/// fake, so view-model tests drive TerminalsModel through the slice contract:
/// a surface per observed scope that lists, creates, selects, renames, and
/// closes on the fake, and answers each command with the surface after it.
/// It does not stream output.
@MainActor final class TerminalsCoreDouble {
    private weak var core: ScriptedCoreClient?
    private let rpc: any TerminalsRPC
    private var surfaces: [String: ClientTerminalsSlice] = [:]

    /// A scripted core whose terminal surfaces run over `rpc`; it owns the double.
    static func core(over rpc: any TerminalsRPC) -> ScriptedCoreClient {
        let core = ScriptedCoreClient()
        let double = TerminalsCoreDouble(rpc: rpc, core: core)
        core.asyncHandler = { command in try await double.handle(command) }
        return core
    }

    private init(rpc: any TerminalsRPC, core: ScriptedCoreClient) {
        self.rpc = rpc
        self.core = core
    }

    private func handle(_ command: ClientCommand) async throws -> ClientResult {
        guard case .terminals(let terminals)? = command.command else { return .with { $0.done = ClientDone() } }
        let scope = terminals.scope
        guard let core, core.isObserved(.terminals, scope: scope) else {
            throw CoreFailure(kind: .invalid, message: "Open the terminals first.")
        }
        let target = surfaces[scope]?.target ?? ClientTerminalTarget()
        switch terminals.action {
        case .bind(let next)?:
            guard next != target else { break }
            let active = surfaces[scope]?.active ?? false
            surfaces[scope] = .with {
                $0.target = next
                $0.active = active
            }
        case .active(let toggle)?:
            update(scope) { $0.active = toggle.on }
        case .load?:
            do {
                let listed = try await rpc.terminals(
                    projectID: target.kind == .machine ? "" : target.projectID, cardID: target.cardID
                ).terminals.filter { target.kind != .card || $0.cardID == target.cardID }
                update(scope) { view in
                    view.terminals = listed
                    view.error = ""
                    if !listed.contains(where: { $0.id == view.selectedID }) {
                        view.selectedID = listed.first?.id ?? ""
                    }
                }
            } catch {
                update(scope) { $0.error = error.localizedDescription }
            }
        case .select(let terminal)?:
            update(scope) { $0.selectedID = terminal.terminalID }
        case .create(let create)?:
            var request = Dieter_V1_CreateTerminalRequest()
            request.projectID = target.projectID
            request.cardID = target.cardID
            request.machineHome = target.kind == .machine
            request.name = create.name
            request.shell = create.shell
            request.workingDirectory =
                create.workingDirectory.isEmpty && target.kind == .card ? "." : create.workingDirectory
            request.columns = create.columns
            request.rows = create.rows
            let created = try await rpc.createTerminal(request)
            update(scope) { view in
                view.terminals.removeAll { $0.id == created.id }
                view.terminals.append(created)
                view.selectedID = created.id
            }
            publish(scope)
            return .with { $0.terminal = created }
        case .rename(let rename)?:
            let renamed = try await rpc.renameTerminal(id: rename.terminalID, name: rename.name)
            update(scope) { view in
                if let index = view.terminals.firstIndex(where: { $0.id == renamed.id }) {
                    view.terminals[index] = renamed
                }
            }
        case .close(let terminal)?:
            try await rpc.closeTerminal(id: terminal.terminalID)
            update(scope) { view in
                view.terminals.removeAll { $0.id == terminal.terminalID }
                if view.selectedID == terminal.terminalID { view.selectedID = view.terminals.first?.id ?? "" }
            }
        default:
            break
        }
        publish(scope)
        return .with { $0.terminals = surfaces[scope] ?? ClientTerminalsSlice() }
    }

    private func update(_ scope: String, _ change: (inout ClientTerminalsSlice) -> Void) {
        var view = surfaces[scope] ?? ClientTerminalsSlice()
        change(&view)
        surfaces[scope] = view
    }

    private func publish(_ scope: String) {
        guard let view = surfaces[scope] else { return }
        core?.emit(.terminals, scope: scope) { $0.terminals = view }
    }
}
