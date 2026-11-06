import DieterAPI
import Testing
@testable import DieterMacKit

/// Project setup drafts, remote paths, and the execution destinations a project offers.
struct ProjectsTests {
    @Test func projectSetupBuildsExistingAndNewGitRequests() {
        var draft = ProjectSetupDraft()
        draft.mode = .existing
        draft.path = "  /srv/repo  "
        draft.name = "  Atlas  "
        draft.summary = "  Main service  "
        draft.prompt = "  Preserve local changes.  "
        draft.boardName = "  Delivery  "
        draft.workflow = "direct"

        let existing = draft.request()
        #expect(existing.mode == "open")
        #expect(existing.path == "/srv/repo")
        #expect(existing.name == "Atlas")
        #expect(existing.summary == "Main service")
        #expect(existing.prompt == "Preserve local changes.")
        #expect(existing.boardName == "Delivery")
        #expect(existing.workflow == "direct")

        draft.mode = .newRepository
        #expect(draft.request().mode == "create")
    }

    @Test func remoteProjectPathsSupportDaemonSeparatorsAndSafeFolderNames() {
        #expect(RemoteProjectPath.lastComponent("/srv/worktrees/feature/") == "feature")
        #expect(RemoteProjectPath.lastComponent("C:\\src\\feature") == "feature")
        #expect(RemoteProjectPath.joining("/srv/projects", "atlas", separator: "/") == "/srv/projects/atlas")
        #expect(RemoteProjectPath.joining("C:\\src\\", "atlas", separator: "\\") == "C:\\src\\atlas")
        #expect(RemoteProjectPath.parentAndName("/srv/projects/atlas") == ("/srv/projects", "atlas"))
        #expect(RemoteProjectPath.validDirectoryName("atlas"))
        #expect(!RemoteProjectPath.validDirectoryName(".."))
        #expect(!RemoteProjectPath.validDirectoryName("feature/one"))
        #expect(!RemoteProjectPath.validDirectoryName("feature\\one"))
    }

    @Test func projectNameSuggestionNeverOverwritesACustomName() {
        let initial = RemoteProjectPath.updatingSuggestedName(
            currentName: "", previousSuggestion: "", path: "/srv/atlas"
        )
        #expect(initial.name == "atlas")
        #expect(initial.suggestion == "atlas")

        let automatic = RemoteProjectPath.updatingSuggestedName(
            currentName: initial.name, previousSuggestion: initial.suggestion, path: "/srv/orion"
        )
        #expect(automatic.name == "orion")

        let custom = RemoteProjectPath.updatingSuggestedName(
            currentName: "Customer API", previousSuggestion: automatic.suggestion, path: "/srv/gateway"
        )
        #expect(custom.name == "Customer API")
        #expect(custom.suggestion == "gateway")
    }

    @Test func projectDestinationsGroupDuplicateNamesByOwningMachine() throws {
        let gateway = MachineEndpoint(name: "Gateway", host: "example.com", port: 443, secure: true)
        let home = MachineEndpoint(
            name: "mini-home", host: gateway.host, port: gateway.port, secure: true,
            daemonID: "home", online: true, releaseVersion: "0.4.92"
        )
        let office = MachineEndpoint(
            name: "mini-office", host: gateway.host, port: gateway.port, secure: true,
            daemonID: "office", online: false, releaseVersion: "0.4.57"
        )
        var homeProject = Dieter_V1_Project()
        homeProject.id = "p_home"
        homeProject.name = "dieter"
        var homeCheckout = Dieter_V1_Checkout(); homeCheckout.id = "co_home"; homeCheckout.daemonID = "home"
        homeCheckout.path = "/Users/home/Development/dieter"; homeProject.checkouts = [homeCheckout]
        var officeProject = Dieter_V1_Project()
        officeProject.id = "p_office"
        officeProject.name = "dieter"
        var officeCheckout = Dieter_V1_Checkout(); officeCheckout.id = "co_office"; officeCheckout.daemonID = "office"
        officeCheckout.path = "/Users/office/Development/dieter"; officeProject.checkouts = [officeCheckout]

        let groups = ProjectDestinationCatalog.groups(
            projects: [officeProject, homeProject],
            endpoints: [office, home]
        )

        #expect(groups.map(\.machineName) == ["mini-home", "mini-office"])
        #expect(groups.map(\.title) == ["mini-home · Online", "mini-office · Offline"])
        #expect(groups.map { $0.destinations.map(\.project.name) } == [["dieter"], ["dieter"]])
        let destination = try #require(ProjectDestinationCatalog.destination(projectID: officeProject.id, in: groups))
        #expect(destination.title == "dieter · mini-office")
        #expect(destination.detail == "Offline · ~/Development/dieter")
    }

    @Test func projectWithoutACheckoutHasNoExecutionDestination() throws {
        let machine = MachineEndpoint(
            name: "Studio Mac", host: "example.com", port: 443, secure: true,
            daemonID: "studio", online: true
        )
        var project = Dieter_V1_Project()
        project.id = "p_studio"
        project.name = "Dieter"
        project.path = "/work/dieter"

        let groups = ProjectDestinationCatalog.groups(
            projects: [project],
            endpoints: [machine]
        )

        #expect(groups.isEmpty)
    }

    @Test func projectDestinationDefaultsToTheCurrentMachineAndAllowsAnExplicitCheckoutOverride() throws {
        let current = MachineEndpoint(
            name: "Zulu current Mac", host: "example.com", port: 443, secure: true,
            daemonID: "current", online: true
        )
        let remote = MachineEndpoint(
            name: "Alpha remote Mac", host: "example.com", port: 443, secure: true,
            daemonID: "remote", online: true
        )
        var project = Dieter_V1_Project()
        project.id = "p_shared"
        project.name = "Shared"
        var currentCheckout = Dieter_V1_Checkout()
        currentCheckout.id = "co_current"; currentCheckout.projectID = project.id
        currentCheckout.daemonID = "current"; currentCheckout.path = "/current/shared"
        var remoteCheckout = Dieter_V1_Checkout()
        remoteCheckout.id = "co_remote"; remoteCheckout.projectID = project.id
        remoteCheckout.daemonID = "remote"; remoteCheckout.path = "/remote/shared"
        project.checkouts = [remoteCheckout, currentCheckout]

        let groups = ProjectDestinationCatalog.groups(
            projects: [project],
            endpoints: [remote, current]
        )

        let defaultDestination = try #require(
            ProjectDestinationCatalog.preferredDestination(
                preferredMachineID: current.id,
                preferredProjectID: project.id,
                in: groups
            ))
        #expect(defaultDestination.checkoutID == currentCheckout.id)
        #expect(defaultDestination.machineID == current.id)

        let explicitDestination = try #require(
            ProjectDestinationCatalog.preferredDestination(
                preferredMachineID: current.id,
                preferredProjectID: project.id,
                preferredCheckoutID: remoteCheckout.id,
                in: groups
            ))
        #expect(explicitDestination.checkoutID == remoteCheckout.id)
        #expect(explicitDestination.machineID == remote.id)

        let selectedRemoteProject = try #require(
            ProjectDestinationCatalog.preferredDestination(
                preferredMachineID: remote.id,
                preferredProjectID: project.id,
                in: groups
            ))
        #expect(selectedRemoteProject.checkoutID == remoteCheckout.id)
    }
}
