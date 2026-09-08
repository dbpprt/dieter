import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

enum BoardCardMergePolicy {
    static func canMerge(_ source: Dieter_V1_Card, into target: Dieter_V1_Card) -> Bool {
        source.id != target.id && !source.boardID.isEmpty && source.boardID == target.boardID &&
        source.projectID == target.projectID && !source.archived && !target.archived &&
        source.mergedIntoCardID.isEmpty && target.mergedIntoCardID.isEmpty &&
        BoardAgentStatus.resolve(source) != .running && !target.initialPromptSentAt.isEmpty
    }
}

@MainActor @Observable
final class BoardCardDropState {
    var targeted = false
    var payload: String?
    var mergeReady = false
    private var generation = UUID()
    private var timer: Task<Void, Never>?

    func enter(_ provider: NSItemProvider, eligible: @escaping @MainActor (String) -> Bool) {
        reset()
        targeted = true
        let token = generation
        provider.loadObject(ofClass: NSString.self) { object, _ in
            let value = object as? String
            Task { @MainActor [weak self] in
                guard let self, self.targeted, self.generation == token, let value else { return }
                self.payload = value
                guard eligible(value) else { return }
                self.timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, self.targeted, self.generation == token, eligible(value) else { return }
                    self.mergeReady = true
                }
            }
        }
    }

    func reset() {
        timer?.cancel(); timer = nil
        generation = UUID()
        targeted = false; payload = nil; mergeReady = false
    }
}

struct BoardCardDropDelegate: DropDelegate {
    let state: BoardCardDropState
    let eligible: @MainActor (String) -> Bool
    let drop: @MainActor (String, Bool) -> Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.text]).first else { return }
        state.enter(provider, eligible: eligible)
    }
    func dropExited(info: DropInfo) { state.reset() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        if let value = state.payload {
            let merge = state.mergeReady && eligible(value)
            state.reset()
            return drop(value, merge)
        }
        state.reset()
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            let value = object as? String
            Task { @MainActor in if let value { _ = drop(value, false) } }
        }
        return true
    }
}
