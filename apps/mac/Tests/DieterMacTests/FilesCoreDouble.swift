import DieterAPI
import DieterCore
import Foundation
import GRPCCore
import SharedCore

/// The shared core's files surfaces (`Files.kt`) over a `FilesRPC` fake, so
/// view-model tests drive FilesModel through the slice contract: a surface per
/// observed scope, reads and saves guarded by bind and read generations, a
/// conflict that keeps the editor's text, an unchanged document left out of
/// updates, and each command answered with the surface after it.
@MainActor final class FilesCoreDouble {
    private weak var core: ScriptedCoreClient?
    private let rpc: any FilesRPC
    private var surfaces: [String: Surface] = [:]

    /// A scripted core whose files surfaces run over `rpc`; it owns the double.
    static func core(over rpc: any FilesRPC) -> ScriptedCoreClient {
        let core = ScriptedCoreClient()
        let double = FilesCoreDouble(rpc: rpc, core: core)
        core.asyncHandler = { command in try await double.handle(command) }
        return core
    }

    private final class Surface {
        var view = ClientFilesSlice()
        var bound: UInt64 = 0
        var reads: UInt64 = 0
        var published: Dieter_V1_FileDocument??
        var target: ClientFilesTarget? { view.hasTarget ? view.target : nil }
        var document: Dieter_V1_FileDocument? { view.hasDocument ? view.document : nil }
    }

    private init(rpc: any FilesRPC, core: ScriptedCoreClient) {
        self.rpc = rpc
        self.core = core
    }

    private func handle(_ command: ClientCommand) async throws -> ClientResult {
        guard case .files(let files)? = command.command else { return .with { $0.done = ClientDone() } }
        guard let core, core.isObserved(.files, scope: files.scope) else {
            throw CoreFailure(kind: .invalid, message: "Open the files surface first.")
        }
        let surface = surfaces[files.scope] ?? Surface()
        surfaces[files.scope] = surface
        let publish: () -> Void = { [weak self] in self?.publish(files.scope, surface) }
        switch files.action {
        case .bind(let target)?:
            let next = target.daemonID.isEmpty || target.projectID.isEmpty ? nil : target
            guard next != surface.target else { break }
            surface.bound += 1
            surface.reads += 1
            surface.view = ClientFilesSlice()
            if let next { surface.view.target = next }
            publish()
        case .load(let path)?:
            try await load(surface, path.path.isEmpty ? surface.view.directory : path.path, publish)
        case .navigate(let path)?:
            try await load(surface, path.path, publish)
        case .open(let path)?:
            try await open(surface, path.path, publish)
        case .reload?:
            let path = surface.document?.path ?? surface.view.selectedPath
            if !path.isEmpty { try await open(surface, path, publish) }
        case .save(let text)?:
            if let saved = try await save(surface, text.text, publish) {
                return .with { $0.fileDocument = saved }
            }
        case .delete(let delete)?:
            let target = try require(surface)
            let bound = surface.bound
            try await rpc.deleteFile(
                .with {
                    $0.projectID = target.projectID; $0.cardID = target.cardID
                    $0.path = delete.path; $0.recursive = delete.recursive
                })
            guard bound == surface.bound else { break }
            let selected = surface.view.selectedPath
            if selected == delete.path || selected.hasPrefix(delete.path + "/") { close(surface) }
            publish()
            try await load(surface, surface.view.directory, publish)
        case .close?:
            close(surface)
            publish()
        default:
            break
        }
        var slice = surface.view
        slice.documentUnchanged = false
        slice.documentKey = Self.documentKey(slice)
        return .with { $0.files = slice }
    }

    private func require(_ surface: Surface) throws -> ClientFilesTarget {
        guard let target = surface.target else {
            throw CoreFailure(kind: .permanent, message: "Choose a project first.")
        }
        return target
    }

    private func load(_ surface: Surface, _ path: String, _ publish: () -> Void) async throws {
        let target = try require(surface)
        let bound = surface.bound
        surface.view.listingLoading = true
        publish()
        do {
            let listing = try await rpc.listFiles(
                .with {
                    $0.projectID = target.projectID; $0.cardID = target.cardID
                    $0.checkoutID = target.cardID.isEmpty ? target.checkoutID : ""
                    $0.path = path; $0.showHidden = surface.view.showHidden
                })
            guard bound == surface.bound else { return }
            surface.view.entries = listing.entries
            surface.view.directory = listing.path
            surface.view.listingError = ""
        } catch {
            guard bound == surface.bound else { return }
            surface.view.listingError = error.localizedDescription
        }
        surface.view.listingLoading = false
        publish()
    }

    private func open(_ surface: Surface, _ path: String, _ publish: () -> Void) async throws {
        let target = try require(surface)
        let bound = surface.bound
        surface.reads += 1
        let read = surface.reads
        if surface.view.selectedPath != path { surface.view.clearDocument() }
        surface.view.selectedPath = path
        surface.view.documentLoading = true
        surface.view.documentError = ""
        surface.view.conflict = false
        publish()
        do {
            let document = try await rpc.readFile(
                .with {
                    $0.projectID = target.projectID; $0.cardID = target.cardID
                    $0.checkoutID = target.cardID.isEmpty ? target.checkoutID : ""
                    $0.path = path
                })
            guard bound == surface.bound, read == surface.reads else { return }
            surface.view.document = document
        } catch {
            guard bound == surface.bound, read == surface.reads else { return }
            surface.view.documentError = error.localizedDescription
        }
        surface.view.documentLoading = false
        publish()
    }

    private func save(_ surface: Surface, _ text: String, _ publish: () -> Void) async throws
        -> Dieter_V1_FileDocument?
    {
        let target = try require(surface)
        guard let document = surface.document, !surface.view.saving, !document.binary else { return nil }
        let bound = surface.bound, read = surface.reads
        surface.view.saving = true
        surface.view.documentError = ""
        surface.view.conflict = false
        publish()
        defer {
            if bound == surface.bound {
                surface.view.saving = false
                publish()
            }
        }
        do {
            let saved = try await rpc.saveFile(
                .with {
                    $0.projectID = target.projectID; $0.cardID = target.cardID
                    $0.checkoutID = target.cardID.isEmpty ? target.checkoutID : ""
                    $0.path = document.path; $0.content = text; $0.revision = document.revision
                })
            if bound == surface.bound, read == surface.reads { surface.view.document = saved }
            return saved
        } catch let error as RPCError where error.code == .aborted {
            guard bound == surface.bound, read == surface.reads else { return nil }
            let name = (document.path as NSString).lastPathComponent
            let message = "“\(name)” changed on disk. Reload it to see the new version, or keep editing your copy."
            surface.view.conflict = true
            surface.view.documentError = message
            throw CoreFailure(kind: .conflict, message: message)
        } catch {
            guard bound == surface.bound, read == surface.reads else { return nil }
            surface.view.documentError = error.localizedDescription
            throw CoreFailure(kind: .permanent, message: error.localizedDescription)
        }
    }

    private func close(_ surface: Surface) {
        surface.reads += 1
        surface.view.selectedPath = ""
        surface.view.clearDocument()
        surface.view.documentLoading = false
        surface.view.documentError = ""
        surface.view.conflict = false
    }

    /// Emits the surface the way the core does: a document equal to the last
    /// one sent is left out and marked unchanged.
    private func publish(_ scope: String, _ surface: Surface) {
        var slice = surface.view
        let document = surface.document
        if let last = surface.published, last == document {
            slice.clearDocument()
            slice.documentUnchanged = true
        }
        surface.published = .some(document)
        slice.documentKey = Self.documentKey(slice)
        core?.emit(.files, scope: scope) { $0.files = slice }
    }

    /// A key per target and selected path, as the core gives every document.
    private static func documentKey(_ slice: ClientFilesSlice) -> String {
        guard slice.hasTarget, !slice.selectedPath.isEmpty else { return "" }
        let target = slice.target
        return [target.daemonID, target.projectID, target.checkoutID, target.cardID, slice.selectedPath]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
}
