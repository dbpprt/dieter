#if os(iOS)
    import DieterAPI
    import Foundation
    import Observation
    import SharedCore

    /// One board as the core's board view lays it out (`SLICE_BOARD_VIEW`):
    /// lanes, the cards each shows, and what each card offers. Every view
    /// owns its own scope, so two boards on screen never share a surface.
    @MainActor
    @Observable
    final class IOSBoardViewModel {
        private(set) var slice = ClientBoardViewSlice()
        @ObservationIgnored let scope: String
        @ObservationIgnored private(set) var target = ClientBoardViewTarget()
        @ObservationIgnored private var core: CoreClient?
        @ObservationIgnored private var subscription: SliceSubscription?
        /// The core takes commands for the view once it has shown it.
        @ObservationIgnored private var shown = false
        @ObservationIgnored private var waiting: [(inout ClientBoardViewCommand) -> Void] = []
        @ObservationIgnored private var queued: Task<Void, Never>?
        @ObservationIgnored var onFailure: (@MainActor (any Error) -> Void)?

        init(scope: String = "ios-board-\(UUID().uuidString.lowercased())") {
            self.scope = scope
        }

        /// Observes the core's view of the board.
        func attach(_ core: CoreClient) {
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
        func detach() {
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

        private func fold(_ value: ClientBoardViewSlice) {
            if !shown {
                shown = true
                let waiting = waiting
                self.waiting = []
                for build in waiting { send(build) }
            }
            // A view of another board, or of the board before a rebind, is stale.
            guard value.target.boardID == target.boardID else { return }
            if slice != value { slice = value }
        }

        /// Shows `boardID`, narrowed by a state and the search text.
        func bind(boardID: String, state: ClientBoardStateFilter = .all, query: String = "") {
            let next = ClientBoardViewTarget.with {
                $0.boardID = boardID
                $0.state = state
                $0.query = query
            }
            guard next != target else { return }
            target = next
            send { $0.bind = next }
        }

        /// Drops a card at the end of a lane, as this view shows it.
        func move(cardID: String, toLane laneID: String) {
            send {
                $0.drop = .with {
                    $0.cardID = cardID
                    $0.laneID = laneID
                }
            }
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
#endif
