import SwiftUI

/// A conversation's Changes, wherever they live: its own worktree's review, or
/// the project checkout a project-directory conversation shares. The core says
/// which (`WorktreeChangesModel.isCheckout`); the view never decides by mode.
/// Until it knows, the review loads and shows its progress.
struct ConversationChangesView: View {
    @Bindable var model: WorktreeChangesModel
    let projectName: String
    var background: Color = DieterTheme.background
    var active = true
    var isLive = true
    var bindingRevision = 0

    var body: some View {
        if model.isCheckout {
            ProjectChangesView(
                model: model.checkout, projectName: projectName, active: active, isLive: isLive,
                bindingRevision: bindingRevision)
        } else {
            WorkspaceChangesView(model: model, background: background, active: active)
        }
    }
}
