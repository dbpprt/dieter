#if os(iOS)
    import DieterAPI
    import DieterShared
    import Foundation
    import Observation
    import SharedCore

    /// One open conversation as the shared core presents it: its transcript
    /// rows, state, and failure from SLICE_CONVERSATION, history paging, and
    /// the composer's draft. The core owns the stream, retries, the agent
    /// pickers, and the transcript cache; this folds its updates and sends
    /// the conversation's commands.
    @MainActor
    @Observable
    final class IOSConversationModel {
        let cardID: String
        /// The slice as last folded; nil until the first snapshot.
        private(set) var slice: ClientConversationSlice?
        /// Every loaded message by its timeline key: its ID, else "position:<index>".
        private(set) var messagesByKey: [String: Dieter_V1_UiMessage] = [:]
        /// The observation failed to open, e.g. an unknown card.
        private(set) var failure: String?
        /// Unsent text, saved by the core per conversation.
        var draftText = "" {
            didSet {
                guard draftText != oldValue else { return }
                draftRevision &+= 1
                if let target = draftTarget { drafts?.update(draftText, for: target) }
            }
        }
        /// Attachments for the next message; they live as long as this screen.
        var draftAttachments: [Dieter_V1_MessagePart] = [] {
            didSet { if draftAttachments != oldValue { draftRevision &+= 1 } }
        }
        private(set) var sending = false
        /// A queued message is being removed or pulled back into the draft.
        private(set) var queueActionID: String?
        private(set) var retryingFailure = false

        @ObservationIgnored private let core: CoreClient
        @ObservationIgnored private let drafts: CoreDraftTexts?
        @ObservationIgnored private let show: @MainActor (any Error) -> Void
        @ObservationIgnored private var subscription: SliceSubscription?
        @ObservationIgnored private var updates: UInt64 = 0
        @ObservationIgnored private var draftRevision: UInt64 = 0
        @ObservationIgnored private var draftTarget: WorkspaceTarget?

        init(
            cardID: String, core: CoreClient, drafts: CoreDraftTexts? = nil,
            show: @escaping @MainActor (any Error) -> Void = { _ in }
        ) {
            self.cardID = cardID
            self.core = core
            self.drafts = drafts
            self.show = show
        }

        // MARK: - Observing

        /// Observes the conversation through the core, which opens it on the
        /// machine that runs it; cached messages show at once.
        func observe() {
            guard subscription == nil else { return }
            subscription = SliceSubscription(
                client: core, slice: .conversation, scope: cardID,
                onReset: { [weak self] in self?.slice = nil }
            ) { [weak self] update in
                self?.fold(update)
            }
        }

        func close() {
            subscription?.close()
            subscription = nil
        }

        private func fold(_ update: ClientUpdate) {
            switch update.value {
            case .conversation(let value):
                present(value)
            case .conversationDelta(let delta):
                guard let slice else { return }
                present(slice.applying(delta))
            case .failure(let value):
                failure = value.message
            default:
                return
            }
        }

        private func present(_ next: ClientConversationSlice) {
            updates &+= 1
            if slice?.messages != next.messages {
                var keyed: [String: Dieter_V1_UiMessage] = [:]
                for (index, message) in next.messages.enumerated() {
                    keyed[message.id.isEmpty ? "position:\(index)" : message.id] = message
                }
                messagesByKey = keyed
            }
            if slice != next { slice = next }
            bindDraft(daemonID: next.daemonID)
        }

        /// Drafts are kept per machine; the saved text fills an untouched composer.
        private func bindDraft(daemonID: String) {
            guard !daemonID.isEmpty, draftTarget?.daemonID != daemonID else { return }
            let target = WorkspaceTarget(
                endpointID: IOSAppModel.endpointID(daemonID: daemonID), projectID: "", conversationID: cardID)
            draftTarget = target
            if draftText.isEmpty, draftRevision == 0, let saved = drafts?.text(for: target), !saved.isEmpty {
                draftText = saved
                draftRevision = 0
            } else if !draftText.isEmpty {
                // Typed before the conversation's machine was known.
                drafts?.update(draftText, for: target)
            }
        }

        // MARK: - Reading

        var card: Dieter_V1_Card? { slice?.hasCard == true ? slice?.card : nil }
        var state: ClientConversationState { slice?.state ?? ClientConversationState() }
        var timeline: [ClientTimelineItem] { slice?.timeline ?? [] }
        var queue: [Dieter_V1_QueuedMessage] { slice?.conversation.queue ?? [] }
        var turnFailure: ClientTurnFailure? { slice?.hasTurnFailure == true ? slice?.turnFailure : nil }
        var agent: ClientAgentControlsState? { slice?.state.hasAgent == true ? slice?.state.agent : nil }
        var hasEarlier: Bool { slice?.hasEarlier_p ?? false }
        var loadingEarlier: Bool { slice?.loadingEarlier ?? false }
        var browsingEarlier: Bool { slice?.browsingEarlier ?? false }
        var retrying: Bool { slice?.retrying ?? false }
        var daemonID: String { slice?.daemonID ?? "" }
        /// Nothing to show yet: the first snapshot, or a load without content.
        var loading: Bool {
            guard let slice else { return failure == nil }
            return slice.loading && !slice.hasCard && slice.messages.isEmpty
        }
        var error: String? {
            if let failure { return failure }
            guard let error = slice?.error, !error.isEmpty else { return nil }
            return error
        }
        /// Whether the composer holds something to send.
        var hasDraft: Bool {
            !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty
        }
        var turnStartedAt: Date? { Date(epochMillis: state.turnStartedAtMillis) }

        /// The message a timeline step renders, by the step's key.
        func message(for step: ClientTimelineStep) -> Dieter_V1_UiMessage? {
            if !step.messageID.isEmpty, let message = messagesByKey[step.messageID] { return message }
            let key = step.id.components(separatedBy: ":part:").first ?? ""
            return messagesByKey[key]
        }

        /// The part a timeline step renders: its message's part, with coalesced prose as its text.
        func part(for step: ClientTimelineStep) -> Dieter_V1_MessagePart? {
            guard let message = message(for: step), message.parts.indices.contains(Int(step.partIndex)) else {
                return nil
            }
            var part = message.parts[Int(step.partIndex)]
            if !step.text.isEmpty { part.text = step.text }
            return part
        }

        /// What a row's "copy message" action copies, as the core words it.
        func copyText(_ row: ClientTimelineItem) -> String {
            let messages = ClientTimelineMessages.with { value in
                value.messages = row.messageIds.compactMap { messagesByKey[$0] }
            }
            return SharedRules.shared.doCopyText(messages: messages.rulesData)
        }

        /// The task plans a row shows, at their latest revision.
        func taskPlans(ids: [String]) -> [Dieter_V1_TaskPlan] {
            guard !ids.isEmpty else { return [] }
            let plans = slice?.conversation.taskPlans ?? []
            return ids.compactMap { id in plans.filter { $0.id == id }.max { $0.revision < $1.revision } }
        }

        /// The delegated agents a row shows, in the row's order.
        func subagents(ids: [String]) -> [Dieter_V1_Subagent] {
            guard !ids.isEmpty else { return [] }
            let agents = slice?.conversation.subagents ?? []
            return ids.compactMap { id in agents.first { $0.id == id } }
        }

        // MARK: - History

        /// Loads the page before the loaded history, then waits for the
        /// update that carries it so the view can keep its reading position.
        @discardableResult
        func loadEarlierMessages() async -> Bool {
            guard !loadingEarlier, hasEarlier else { return false }
            let before = updates
            let count = slice?.messages.count ?? 0
            do {
                let result = try await core.dispatch { $0.loadEarlierMessages = .with { $0.cardID = cardID } }
                guard result.pageLoaded.loaded else { return false }
                let deadline = ContinuousClock.now + .seconds(2)
                while updates == before || (slice?.messages.count ?? 0) == count, ContinuousClock.now < deadline {
                    try await DieterTaskSleep.milliseconds(16)
                }
                return true
            } catch {
                show(error)
                return false
            }
        }

        /// Earlier pages are loaded ahead of the live window, or it was paged away.
        var holdsHistory: Bool { (slice?.earlierCount ?? 0) > 0 || browsingEarlier }

        /// Drops loaded history and follows the live window again; false when
        /// there was none to drop.
        @discardableResult
        func returnToLatest() -> Bool {
            guard holdsHistory, !loadingEarlier else { return false }
            Task { [core, cardID] in _ = try? await core.dispatch { $0.returnToLatest = .with { $0.cardID = cardID } } }
            return true
        }

        // MARK: - Composer

        /// Sends the draft; the core places it behind a running turn or
        /// queued messages, with the composer's agent choice. The draft
        /// clears unless it changed while sending.
        func send() async {
            guard hasDraft, !sending else { return }
            sending = true
            defer { sending = false }
            let revision = draftRevision
            let text = draftText
            let attachments = draftAttachments
            do {
                // The core sends the trimmed text ahead of the attachments.
                try await core.dispatch {
                    $0.sendMessage = .with {
                        $0.cardID = cardID
                        $0.text = text
                        $0.parts = attachments
                    }
                }
                guard draftRevision == revision else { return }
                draftText = ""
                draftAttachments = []
            } catch {
                show(error)
            }
        }

        /// Removes a queued message; editing brings its text and attachments
        /// back ahead of the draft, as the core restores them.
        @discardableResult
        func removeQueued(_ message: Dieter_V1_QueuedMessage, edit: Bool) async -> Bool {
            guard queueActionID == nil, !sending, !message.id.isEmpty else { return false }
            queueActionID = message.id
            defer { queueActionID = nil }
            do {
                let removed = try await core.dispatch {
                    $0.removeQueuedMessage = .with {
                        $0.cardID = cardID
                        $0.messageID = message.id
                        $0.edit = edit
                    }
                }.queuedMessage
                if edit {
                    let restored = Dieter_V1_QueuedMessage(
                        rules: SharedRules.shared.restoredDraft(message: removed.rulesData, currentText: draftText))
                    draftText = restored.text
                    draftAttachments = restored.parts + draftAttachments
                }
                return true
            } catch {
                show(error)
                return false
            }
        }

        /// Lets the queued message interrupt the running turn now; the core
        /// checks it is the one that may (`state.steerable_id`).
        func steer(_ messageID: String) async {
            guard queueActionID == nil, !messageID.isEmpty else { return }
            queueActionID = messageID
            defer { queueActionID = nil }
            await perform {
                $0.steerConversation = .with {
                    $0.cardID = cardID
                    $0.messageID = messageID
                }
            }
        }

        /// Changes the composer's agent for the next message; `state.agent`
        /// shows the result.
        func chooseAgent(_ choice: ClientAgentChoice.OneOf_Choice) async {
            await perform {
                $0.chooseAgent = .with {
                    $0.cardID = cardID
                    $0.choice = .with { $0.choice = choice }
                }
            }
        }

        // MARK: - Card

        /// Runs the card's saved task now.
        func start() async {
            let attachments = !(slice?.conversation.draftAttachments.isEmpty ?? true)
            await perform {
                $0.startCard = .with {
                    $0.cardID = cardID
                    $0.hasDraftAttachments_p = attachments
                }
            }
        }

        /// Halts the agent.
        func cancel() async {
            await perform { $0.cancelCard = .with { $0.cardID = cardID } }
        }

        func move(toLane lane: String) async {
            await perform {
                $0.moveCard = .with {
                    $0.cardID = cardID
                    $0.lane = lane
                }
            }
        }

        /// Sends the failed turn's request again, once until it runs.
        func retryFailedTurn() async {
            guard !retryingFailure else { return }
            retryingFailure = true
            defer { retryingFailure = false }
            await perform { $0.retryFailedTurn = .with { $0.cardID = cardID } }
        }

        private func perform(_ build: (inout ClientCommand) -> Void) async {
            var command = ClientCommand()
            build(&command)
            do {
                _ = try await core.dispatch(command)
            } catch {
                show(error)
            }
        }
    }
#endif
