import DieterAPI
import DieterShared
import SharedCore

/// The workflows, publish modes, and archive policies project and board forms
/// offer, and what a new project or board starts with, as the core words them.
enum AdminChoices {
    static let options = ClientAdminOptions(rules: SharedRules.shared.adminOptions())

    /// The choice `id` names in `choices`, if any.
    static func choice(_ id: String, in choices: [ClientAdminChoice]) -> ClientAdminChoice? {
        choices.first { $0.id == id }
    }
}
