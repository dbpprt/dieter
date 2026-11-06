import DieterClientAPI
import Foundation
import Observation

/// Agent channels (experimental) as the shared core presents them: the list
/// of the account's project channels with the sidebar's unread count, the
/// selected channel's stream and inspector, and the account's settings. The
/// core lists, watches, groups and words everything; this model only folds
/// its slices and sends its commands.
@MainActor @Observable
final class ChannelsModel {
    /// The list, the empty state, and the selected channel's stream.
    private(set) var slice = ClientChannelsSlice()
    /// The account's switches with this device's unconfirmed changes.
    private(set) var settings = ClientChannelSettingsSlice()
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

    /// Observes the channels and their settings; the core lists channels only
    /// while some setting is on.
    func attach(_ core: CoreClient) {
        guard subscriptions.isEmpty else { return }
        self.core = core
        subscriptions = [
            SliceSubscription(client: core, slice: .channels, scope: scope) { [weak self] update in
                guard let self, case .channels(let value) = update.value else { return }
                self.fold(value)
            },
            SliceSubscription(client: core, slice: .channelSettings) { [weak self] update in
                guard let self, case .channelSettings(let value) = update.value else { return }
                if self.settings != value { self.settings = value }
            },
        ]
    }

    private func fold(_ value: ClientChannelsSlice) {
        if slice != value { slice = value }
    }

    // MARK: Settings

    /// The settings row of a project, or nil before the workspace lists it.
    func projectSetting(_ projectID: String) -> ClientChannelSettingRow? {
        settings.projects.first { $0.id == projectID }
    }

    func boardSetting(_ boardID: String) -> ClientChannelSettingRow? {
        settings.boards.first { $0.id == boardID }
    }

    /// Writes a switch on a reachable machine; the settings show it at once.
    func setSetting(scope: ClientChannelSettingScope, id: String = "", mode: ClientChannelSettingMode) async {
        await run { command in
            command.setSetting = .with {
                $0.scope = scope
                $0.id = id
                $0.mode = mode
            }
        }
    }

    func setGlobal(_ on: Bool) async {
        await setSetting(scope: .global, mode: on ? .on : .off)
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
