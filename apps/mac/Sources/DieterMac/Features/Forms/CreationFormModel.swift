import DieterAPI
import Foundation
import Observation
import SharedCore

/// A creation form's choices and the shared core's preview of them: the
/// defaults it applies, why it cannot be created yet, the agent pickers for
/// the destination machine's catalog, and its wording. The core previews the
/// bound choices again as the workspace and the machines' catalogs change.
@MainActor @Observable
final class CreationFormModel {
    /// What the user chose; empty fields take the core's defaults.
    var intent = ClientCreationIntent()
    /// Attachments travel with the creation, not with every preview.
    var attachments: [Dieter_V1_MessagePart] = []
    private(set) var preview = ClientCreationPreview()
    /// A preview has arrived; until then nothing can be created.
    private(set) var previewed = false
    let chat: Bool
    /// Reusing it never creates a second conversation, so a retry after a
    /// failure is safe.
    @ObservationIgnored private(set) var submissionID = UUID().uuidString
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored private let scope = "mac-creation-\(UUID().uuidString)"
    @ObservationIgnored private var generation: UInt64 = 0

    init(chat: Bool) {
        self.chat = chat
    }

    /// Observes the form's preview surface through `core`.
    func attach(_ core: CoreClient) {
        guard subscription == nil else { return }
        self.core = core
        subscription = SliceSubscription(client: core, slice: .creationPreview, scope: scope) { [weak self] update in
            guard let self, case .creationPreview(let next) = update.value else { return }
            self.fold(next)
        }
    }

    /// Binds the current choices, after `choice` when the user picked an
    /// agent; the picked agent becomes the form's.
    func refresh(choice: ClientAgentChoice.OneOf_Choice? = nil) async {
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
    var lane: String { intent.lane.isEmpty ? preview.intent.lane : intent.lane }

    /// The workspace mode: the chosen one, else the one last chosen.
    var workspaceMode: ConversationWorkspaceMode {
        ConversationWorkspaceMode.projectMode(
            intent.workspaceMode.isEmpty ? preview.intent.workspaceMode : intent.workspaceMode)
    }

    /// Creates the conversation from the choices and attachments.
    func create(using store: DieterStore) async -> Bool {
        var intent = intent
        intent.attachments = attachments
        let created = await store.createConversation(intent, chat: chat, submissionID: submissionID)
        if created { submissionID = UUID().uuidString }
        return created
    }
}
