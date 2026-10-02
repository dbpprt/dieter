import DieterAPI
import Foundation
import Observation
import SharedCore

/// The chats pane's list as the shared core lays it out: pinned chats,
/// folders, and project sections over the account's chats, narrowed by a
/// search, live or archived.
@MainActor @Observable
final class ChatsListModel {
    private(set) var slice = ClientChatsSlice()
    @ObservationIgnored private let scope = "mac-chats"
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored private var core: CoreClient?
    /// The core takes commands for the list once it has shown it; earlier
    /// ones wait until then.
    @ObservationIgnored private var shown = false
    @ObservationIgnored private var waiting: [(inout ClientChatsCommand) -> Void] = []
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored private(set) var query = ""
    @ObservationIgnored private(set) var archived = false
    #if DIETER_UI_SMOKE
        /// The session whose fixture chats the list shows while its core folds are held.
        @ObservationIgnored private weak var fixtureSession: AppSession?
    #endif

    /// Observes the core's list for the pane.
    func attach(_ core: CoreClient) {
        guard subscription == nil else { return }
        self.core = core
        subscription = SliceSubscription(client: core, slice: .chats, scope: scope) { [weak self] update in
            guard let self, case .chats(let value) = update.value else { return }
            self.fold(value)
        }
    }

    func fold(_ value: ClientChatsSlice) {
        if !shown {
            shown = true
            let waiting = waiting
            self.waiting = []
            for build in waiting { send(build) }
        }
        #if DIETER_UI_SMOKE
            if fixtureSession?.coreFoldsHeld == true { return }
        #endif
        if slice != value { slice = value }
    }

    /// Shows chats whose title, summary, project, or folder matches `text`.
    func search(_ text: String) {
        query = text
        send { $0.query = .with { $0.text = text } }
    }

    /// Shows archived chats instead of live ones.
    func showArchived(_ on: Bool) {
        archived = on
        send { $0.showArchived = .with { $0.on = on } }
    }

    /// Loads the archived chats again.
    func reload() {
        send { $0.reload = ClientStep() }
    }

    private func send(_ build: @escaping (inout ClientChatsCommand) -> Void) {
        #if DIETER_UI_SMOKE
            if let fixtureSession, fixtureSession.coreFoldsHeld { showFixture(of: fixtureSession) }
        #endif
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

    #if DIETER_UI_SMOKE
        /// Lays out the chats a UI fixture installed on this Mac only.
        func showFixture(of session: AppSession) {
            fixtureSession = session
            let next = NavigationFixture.chats(
                session.chats, projects: session.projects, navigation: session.navigation, query: query)
            if slice != next { slice = next }
        }
    #endif
}
