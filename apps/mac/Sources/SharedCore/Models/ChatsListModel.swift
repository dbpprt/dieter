import DieterAPI
import Foundation
import Observation

/// The chats pane's list as the shared core lays it out: pinned chats,
/// folders, and project sections over the account's chats, narrowed by a
/// search, live or archived.
@MainActor @Observable
package final class ChatsListModel {
    package private(set) var slice = ClientChatsSlice()
    @ObservationIgnored package let scope: String
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored private var core: CoreClient?
    /// The core takes commands for the list once it has shown it; earlier
    /// ones wait until then.
    @ObservationIgnored private var shown = false
    @ObservationIgnored private var waiting: [(inout ClientChatsCommand) -> Void] = []
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored package private(set) var query = ""
    @ObservationIgnored package private(set) var archived = false
    /// UI fixtures: while it returns a list for the current query, the core's
    /// lists are held back and the fixture's shows instead.
    @ObservationIgnored package var fixture: (@MainActor (_ query: String) -> ClientChatsSlice?)?

    /// `scope` names the list's surface in the core.
    package init(scope: String) {
        self.scope = scope
    }

    /// Observes the core's list for the pane.
    package func attach(_ core: CoreClient) {
        guard subscription == nil else { return }
        self.core = core
        subscription = SliceSubscription(client: core, slice: .chats, scope: scope) { [weak self] update in
            guard let self, case .chats(let value) = update.value else { return }
            self.fold(value)
        }
    }

    package func fold(_ value: ClientChatsSlice) {
        if !shown {
            shown = true
            let waiting = waiting
            self.waiting = []
            for build in waiting { send(build) }
        }
        if fixture?(query) != nil { return }
        if slice != value { slice = value }
    }

    /// Shows chats whose title, summary, project, or folder matches `text`.
    package func search(_ text: String) {
        query = text
        send { $0.query = .with { $0.text = text } }
    }

    /// Shows archived chats instead of live ones.
    package func showArchived(_ on: Bool) {
        archived = on
        send { $0.showArchived = .with { $0.on = on } }
    }

    /// Loads the archived chats again.
    package func reload() {
        send { $0.reload = ClientStep() }
    }

    private func send(_ build: @escaping (inout ClientChatsCommand) -> Void) {
        showFixture()
        guard let core else { return }
        guard shown else {
            waiting.append(build)
            return
        }
        let scope = scope
        let previous = queued
        queued = Task {
            await previous?.value
            var command = ClientChatsCommand()
            command.scope = scope
            build(&command)
            let sent = command
            _ = try? await core.dispatch(.with { $0.chats = sent })
        }
    }

    /// Shows the fixture's list for the current query, if one is installed.
    package func showFixture() {
        guard let next = fixture?(query) else { return }
        if slice != next { slice = next }
    }
}
