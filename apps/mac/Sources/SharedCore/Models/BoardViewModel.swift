import DieterAPI
import Foundation
import Observation

/// One board as the core's board view lays it out (`SLICE_BOARD_VIEW`):
/// lanes, the cards each shows, and what each card offers. Every view owns
/// its own scope, so two boards on screen never share a surface. Commands
/// wait until the core has shown the view, and a resubscribed surface is
/// bound again.
@MainActor
@Observable
package final class BoardViewModel {
    package private(set) var slice = ClientBoardViewSlice()
    @ObservationIgnored package let scope: String
    @ObservationIgnored package private(set) var target = ClientBoardViewTarget()
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private var subscription: SliceSubscription?
    /// The core takes commands for the view once it has shown it.
    @ObservationIgnored private var shown = false
    @ObservationIgnored private var waiting: [(inout ClientBoardViewCommand) -> Void] = []
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored package var onFailure: (@MainActor (any Error) -> Void)?
    /// Called after a slice of the bound board was folded.
    @ObservationIgnored package var onChange: (@MainActor () -> Void)?

    package init(scope: String) {
        self.scope = scope
    }

    /// Observes the core's view of the board.
    package func attach(_ core: CoreClient) {
        guard subscription == nil else { return }
        self.core = core
        subscription = SliceSubscription(
            client: core, slice: .boardView, scope: scope,
            onReset: { [weak self] in self?.reset() }
        ) { [weak self] update in
            guard let self, case .boardView(let value) = update.value else { return }
            self.fold(value)
        }
    }

    /// Stops observing; a later `attach` opens the surface again.
    package func detach() {
        subscription?.close()
        subscription = nil
        reset()
    }

    private func reset() {
        shown = false
        // The resubscribed surface starts unbound; bind it again.
        let target = target
        if !target.boardID.isEmpty { waiting = [{ $0.bind = target }] }
    }

    package func fold(_ value: ClientBoardViewSlice) {
        if !shown {
            shown = true
            let waiting = waiting
            self.waiting = []
            for build in waiting { send(build) }
        }
        // A view of another board, or of the board before a rebind, is stale.
        guard value.target.boardID == target.boardID else { return }
        if slice != value { slice = value }
        onChange?()
    }

    /// Shows the target's board, narrowed by its filters.
    package func bind(_ next: ClientBoardViewTarget) {
        guard next != target else { return }
        target = next
        guard !next.boardID.isEmpty else { return }
        send { $0.bind = next }
    }

    /// Shows `boardID`, narrowed by a state and the search text.
    package func bind(boardID: String, state: ClientBoardStateFilter = .all, query: String = "") {
        bind(
            .with {
                $0.boardID = boardID
                $0.state = state
                $0.query = query
            })
    }

    /// Drops a card into a lane above `beforeCardID` ("" for the lane's end), as this view shows it.
    package func drop(cardID: String, laneID: String, beforeCardID: String = "") {
        send {
            $0.drop = .with {
                $0.cardID = cardID
                $0.laneID = laneID
                $0.beforeCardID = beforeCardID
            }
        }
    }

    /// Waits for every command sent so far.
    package func settle() async {
        await queued?.value
    }

    private func send(_ build: @escaping (inout ClientBoardViewCommand) -> Void) {
        guard let core else { return }
        guard shown else {
            waiting.append(build)
            return
        }
        let scope = scope
        let previous = queued
        queued = Task { [weak self] in
            await previous?.value
            var command = ClientBoardViewCommand()
            command.scope = scope
            build(&command)
            let sent = command
            do {
                _ = try await core.dispatch(.with { $0.boardView = sent })
            } catch {
                self?.onFailure?(error)
            }
        }
    }
}
