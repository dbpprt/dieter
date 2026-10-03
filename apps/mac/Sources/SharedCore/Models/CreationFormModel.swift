import DieterAPI
import Foundation
import Observation

/// A creation form's choices and the shared core's preview of them: the
/// defaults it applies, why it cannot be created yet, the agent pickers for
/// the destination machine's catalog, and its wording. The core previews the
/// bound choices again as the workspace and the machines' catalogs change.
@MainActor @Observable
package final class CreationFormModel {
    /// What the user chose; empty fields take the core's defaults.
    package var intent = ClientCreationIntent()
    /// Attachments travel with the creation, not with every preview.
    package var attachments: [Dieter_V1_MessagePart] = []
    package private(set) var preview = ClientCreationPreview()
    /// A preview has arrived; until then nothing can be created.
    package private(set) var previewed = false
    package let chat: Bool
    /// Reusing it never creates a second conversation, so a retry after a
    /// failure is safe.
    @ObservationIgnored package private(set) var submissionID = UUID().uuidString
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored package let scope: String
    @ObservationIgnored private var generation: UInt64 = 0

    /// `scope` names the form's preview surface; each form needs its own.
    package init(chat: Bool, scope: String = "creation-\(UUID().uuidString)") {
        self.chat = chat
        self.scope = scope
    }

    /// Observes the form's preview surface through `core`.
    package func attach(_ core: CoreClient) {
        guard subscription == nil else { return }
        self.core = core
        subscription = SliceSubscription(client: core, slice: .creationPreview, scope: scope) { [weak self] update in
            guard let self, case .creationPreview(let next) = update.value else { return }
            self.fold(next)
        }
    }

    /// Binds the current choices, after `choice` when the user picked an
    /// agent; the picked agent becomes the form's.
    package func refresh(choice: ClientAgentChoice.OneOf_Choice? = nil) async {
        guard let core else { return }
        generation &+= 1
        let current = generation
        var sent = intent
        sent.attachments = attachments.map { part in
            var named = part
            named.url = ""
            return named
        }
        let command = ClientCreationPreviewCommand.with {
            $0.scope = scope
            $0.intent = sent
            $0.chat = chat
            if let choice { $0.choice = .with { $0.choice = choice } }
        }
        guard let result = try? await core.dispatch(.with { $0.creationPreview = command }) else { return }
        let next = result.creationPreview
        if choice != nil, intent.selection != next.intent.selection {
            intent.selection = next.intent.selection
            // A later binding went out without the pick; bind again with it.
            if current != generation {
                await refresh()
                return
            }
        }
        guard current == generation else { return }
        fold(next)
    }

    private func fold(_ next: ClientCreationPreview) {
        if preview != next { preview = next }
        if !previewed { previewed = true }
    }

    /// The lane the task starts in: the chosen one, else the core's default.
    package var lane: String { intent.lane.isEmpty ? preview.intent.lane : intent.lane }

    /// Creates the conversation from the choices and attachments through
    /// `submit` (the intent, whether it is a chat, and the submission ID);
    /// a success starts a new submission.
    package func create(
        with submit: (_ intent: ClientCreationIntent, _ chat: Bool, _ submissionID: String) async -> Bool
    ) async -> Bool {
        var intent = intent
        intent.attachments = attachments
        let created = await submit(intent, chat, submissionID)
        if created { submissionID = UUID().uuidString }
        return created
    }
}
