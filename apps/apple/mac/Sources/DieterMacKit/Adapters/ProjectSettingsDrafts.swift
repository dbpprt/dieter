import DieterAPI
import Foundation

extension ProjectSettingsDraft {
    /// The project's settings as its form edits them; empty Git settings take the defaults.
    init(project: Dieter_V1_Project) {
        self.init()
        name = project.name
        summary = project.summary
        prompt = project.prompt
        baseRemote = project.baseRemote.isEmpty ? AdminChoices.options.defaultBaseRemote : project.baseRemote
        baseBranch = project.baseBranch.isEmpty ? AdminChoices.options.defaultBaseBranch : project.baseBranch
        validationCommands = project.validationCommands.map(ValidationCommandDraft.init)
    }
}
