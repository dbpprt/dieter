import DieterAPI
import DieterClientAPI
import DieterCore
import Foundation

// Workspace Git forms over dieter.v1 values: validation commands as their
// drafts edit them, and operation forms filled from a card.

extension ValidationCommandDraft {
    init(_ value: Dieter_V1_ValidationCommand) {
        draft = ClientValidationDraft(rules: SharedRules.shared.validationDraft(command: value.rulesData))
    }

    /// The command this draft saves as.
    var value: Dieter_V1_ValidationCommand {
        Dieter_V1_ValidationCommand(rules: SharedRules.shared.validationCommand(draft: draft.rulesData))
    }
}

extension GitOperationKind {
    /// The operation's form as the shared core describes it, filled from `card`.
    func form(card: Dieter_V1_Card? = nil, baseBranch: String = "") -> ClientGitOperationFormSpec {
        ClientGitOperationFormSpec(
            rules: SharedRules.shared.gitOperationForm(
                kind: rawValue, cardTitle: card?.title ?? "", cardPrompt: card?.initialPrompt ?? "",
                pullRequestHeadSha: card?.pullRequest.headSha ?? "", baseBranch: baseBranch))
    }
}
