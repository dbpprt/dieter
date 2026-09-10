import DieterAPI
import Testing
@testable import DieterMac

@Test func projectSettingsDraftRetainsContextAndValidationWhenEditingName() {
    var project = Dieter_V1_Project()
    project.name = "Website"
    project.prompt = "Keep all public pages accessible."
    var validation = Dieter_V1_ValidationCommand()
    validation.name = "Tests"
    validation.executable = "just"
    validation.arguments = ["test", "--offline"]
    project.validationCommands = [validation]
    let original = ProjectSettingsDraft(project: project)
    var edited = original
    edited.name = "Website frontend"
    #expect(edited.isValid)
    #expect(edited.prompt == original.prompt)
    #expect(edited.validationCommands.map(\.value) == original.validationCommands.map(\.value))
    #expect(original.name == "Website")
    edited.validationCommands[0].executable = " "
    #expect(!edited.isValid)
    edited = original
    edited.baseBranch = " "
    #expect(!edited.isValid)
}
