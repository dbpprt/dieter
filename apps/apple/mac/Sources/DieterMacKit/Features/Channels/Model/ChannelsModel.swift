import DieterClientAPI
import Foundation
import Observation

/// Agent channels as the shared core presents them: the list of the account's
/// project channels with the sidebar's unread count and the selected
/// channel's stream and inspector. The core lists, watches, groups and words
/// everything; this model only folds its slice and sends its commands.
@MainActor @Observable
final class ChannelsModel {
    /// The list, the empty state, and the selected channel's stream.
    private(set) var slice = ClientChannelsSlice()
    /// Why the last command failed; the channel view shows it.
    var errorMessage: String?
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private var subscriptions: [SliceSubscription] = []
    @ObservationIgnored let scope: String

    init(scope: String = "mac-channels") {
        self.scope = scope
    }

    var stream: ClientChannelStreamView? { slice.hasStream ? slice.stream : nil }
    var unread: Int { Int(slice.unread) }

    /// Observes the channels.
    func attach(_ core: CoreClient) {
        guard subscriptions.isEmpty else { return }
        self.core = core
        subscriptions = [
            SliceSubscription(client: core, slice: .channels, scope: scope) { [weak self] update in
                guard let self, case .channels(let value) = update.value else { return }
                self.fold(value)
            }
        ]
    }

    private func fold(_ value: ClientChannelsSlice) {
        if slice != value { slice = value }
    }

    // MARK: The channel view

    /// The channel view is on screen (watching, frequent refreshes) or not.
    func setActive(_ active: Bool) async {
        await run { $0.active = .with { $0.on = active } }
    }

    func select(projectID: String) async {
        await run { command in
            command.select = .with { $0.projectID = projectID }
        }
    }

    func refresh() async {
        await run { $0.refresh = ClientStep() }
    }

    /// Posts as the user to everyone, @here or the picked cards; false (with
    /// the failure shown) when it was refused.
    @discardableResult
    func post(
        body: String, to cardIDs: [String], here: Bool = false, kind: ClientChannelMessageKind, wake: Bool
    ) async -> Bool {
        let result = await run { command in
            command.post = .with {
                $0.body = body
                $0.toCardIds = here ? [] : cardIDs
                $0.here = here
                $0.kind = kind
                $0.wake = wake && !here && !cardIDs.isEmpty
            }
        }
        return result != nil
    }

    func pin(_ messageID: String, pinned: Bool) async {
        await run { command in
            command.pin = .with {
                $0.messageID = messageID
                $0.pinned = pinned
            }
        }
    }

    /// The newest message of the selected channel is visible.
    func markRead() async {
        guard let stream, stream.unread > 0 else { return }
        await run { $0.markRead = ClientStep() }
    }

    func release(cardID: String, path: String) async {
        await run { command in
            command.releaseClaim = .with {
                $0.cardID = cardID
                $0.path = path
            }
        }
    }

    /// Runs a command and folds the slice it returns; a failure becomes the
    /// error message.
    @discardableResult
    private func run(_ build: (inout ClientChannelsCommand) -> Void) async -> ClientResult? {
        guard let core else { return nil }
        var command = ClientChannelsCommand()
        command.scope = scope
        build(&command)
        let sent = command
        do {
            let result = try await core.dispatch(.with { $0.channels = sent })
            if case .channels(let value)? = result.result { fold(value) }
            if errorMessage != nil { errorMessage = nil }
            return result
        } catch let failure as CoreFailure {
            errorMessage = failure.message
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
