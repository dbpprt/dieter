import DieterAPI
import DieterClientAPI
import Foundation
import Testing
@testable import DieterMacKit

/// The session's endpoints, connection phase, failure reporting, settings, and work routing.
struct AppSessionTests {
    @Test func daemonEndpointKeepsHostnamePresenceAndGatewayCredentialIdentity() throws {
        let endpoint = MachineEndpoint(
            name: "Studio Mac",
            host: "dieter.example",
            port: 443,
            secure: true,
            daemonID: "daemon-1",
            online: false,
            lastSeenAt: "2026-08-18T12:00:00Z",
            releaseVersion: "0.4.92",
            minimumReleaseVersion: "0.4.80"
        )
        #expect(endpoint.id == "https://dieter.example:443#daemon-1")
        #expect(endpoint.credentialID == "https://dieter.example:443")
        #expect(endpoint.name == "Studio Mac")
        #expect(!endpoint.online)
        // The core's origins round-trip; anything else is not a gateway.
        let gateway = MachineEndpoint(origin: "https://dieter.example:443", name: "Gateway")
        #expect(gateway?.credentialID == endpoint.credentialID)
        #expect(MachineEndpoint(origin: "http://::1:4242", name: "Local")?.host == "::1")
        #expect(MachineEndpoint(origin: "", name: "None") == nil)
    }

    @Test func onlyAuthenticationRequiresAConnectionOverlay() {
        #expect(ConnectionPhase.authenticationRequired.needsConnectionOverlay)
        #expect(!ConnectionPhase.connecting.needsConnectionOverlay)
        #expect(!ConnectionPhase.disconnected.needsConnectionOverlay)
    }

    @Test @MainActor func coreFailuresReportByKindAndTransientOnesStaySilentWhileOffline() {
        let store = DieterStore(liveEnvironment: false)
        store.phase = .disconnected
        store.show(CoreFailure(kind: .transient, message: "The machine is unreachable."))
        #expect(store.errorMessage == nil)
        store.show(CoreFailure(kind: .permanent, message: "This board has no done lane."))
        #expect(store.errorMessage == "This board has no done lane.")

        store.errorMessage = nil
        store.phase = .connected
        store.show(CoreFailure(kind: .transient, message: "The machine is unreachable."))
        #expect(store.errorMessage == "The machine is unreachable.")
        store.errorMessage = nil
        store.show(CancellationError())
        #expect(store.errorMessage == nil)
    }

    @Test @MainActor func notificationSettingIsKeptOnlyUnderItsCoreKey() throws {
        let suite = "DieterNotificationSettingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DieterStore(environment: .testing(defaults: defaults), liveEnvironment: false)
        store.notificationsEnabled = false
        #expect(!store.notificationsEnabled)
        #expect(defaults.string(forKey: "notifications.enabled") == "false")
        #expect(defaults.object(forKey: "DieterNotifications") == nil)
    }

    @Test @MainActor func workRoutesToTheConversationOwnerAndProjectReadsToTheProjectHost() throws {
        let store = DieterStore(liveEnvironment: false)
        let checkoutMachine = MachineEndpoint(
            name: "MBP", host: "mbp.invalid", port: 443, secure: true,
            daemonID: "daemon-mbp", online: true)
        let conversationOwner = MachineEndpoint(
            name: "Mini", host: "mini.invalid", port: 443, secure: true,
            daemonID: "daemon-mini", online: true)
        store.endpoints = [checkoutMachine, conversationOwner]
        store.machineEntries = Dictionary(
            uniqueKeysWithValues: store.endpoints.map { machine in
                (
                    machine.id,
                    ClientMachineEntry.with {
                        $0.id = machine.daemonID ?? ""
                        $0.online = true
                        $0.available = true
                        $0.compatible = true
                    }
                )
            })
        var project = Dieter_V1_Project()
        project.id = "project"
        project.checkouts = [
            .with {
                $0.id = "co"; $0.projectID = "project"; $0.daemonID = "daemon-mbp"
            }
        ]
        store.projectDirectory = [project.id: project]
        store.projectHosts = [project.id: "daemon-mbp"]
        var chat = Dieter_V1_Card()
        chat.id = "chat"
        chat.scope = "chat"
        chat.projectID = "project"
        chat.ownerDaemonID = "daemon-mini"

        let route = try #require(store.conversationWorkspaceRoute(for: chat))
        #expect(route.endpointID == conversationOwner.id)
        #expect(route.machineName == "Mini")
        #expect(store.projectMachine(forProjectID: "project")?.id == checkoutMachine.id)
        #expect(store.projectIsAvailable("project"))
        // A machine the session does not list is still the owner, shown as offline.
        chat.ownerDaemonID = "daemon-gone"
        #expect(store.machine(for: chat)?.online == false)
        #expect(store.endpointID(for: chat) == "\(store.activeGateway.credentialID)#daemon-gone")
    }
}
