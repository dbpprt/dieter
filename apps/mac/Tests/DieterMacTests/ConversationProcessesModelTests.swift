import DieterAPI
import DieterCore
import Foundation
import SharedCore
import Testing
@testable import DieterMac

// The processes view's adapter over the core's processes surface. Bounded
// output, refresh, and stop on the real daemon are covered by the core's
// ClientApiProcessesEndToEndTest; these pin what the Mac sends and folds.
@MainActor struct ConversationProcessesModelTests {
    private func execution(_ id: String, card: String = "card", status: String = "running") -> Dieter_V1_Execution {
        var value = Dieter_V1_Execution()
        value.id = id; value.projectID = "project"; value.cardID = card; value.status = status; value.name = id
        return value
    }

    private func sent(_ core: ScriptedCoreClient) -> [ClientProcessesCommand] {
        core.commands.compactMap { if case .processes(let command)? = $0.command { command } else { nil } }
    }

    private func settle(_ model: ConversationProcessesModel) async { await model.refresh() }

    @Test func processesFollowTheConversationsMachineAndIgnoreAnotherTarget() async {
        let core = ScriptedCoreClient()
        let model = ConversationProcessesModel()
        model.bind(
            target: .init(endpointID: "origin#daemon-a", projectID: "project", conversationID: "card"), core: core)
        model.active = true
        await settle(model)
        guard case .bind(let bind)? = sent(core).last?.action else {
            Issue.record("expected a bind: \(sent(core))")
            return
        }
        #expect(bind.daemonID == "daemon-a" && bind.projectID == "project" && bind.cardID == "card" && bind.active)
        let scope = sent(core)[0].scope
        #expect(core.isObserved(.processes, scope: scope))

        core.emit(.processes, scope: scope) {
            $0.processes = .with {
                $0.daemonID = "daemon-a"; $0.projectID = "project"; $0.cardID = "card"
                $0.processes = [self.execution("own")]
                $0.selectedID = "own"
                $0.stdout = Data("ready\n".utf8)
                $0.stderr = Data("warning".utf8)
                $0.outputTruncated = true
                $0.running = 1
                $0.canStop = true
            }
        }
        #expect(model.processes.map(\.id) == ["own"] && model.selectedID == "own")
        #expect(model.running == 1 && model.canStop)
        #expect(String(decoding: model.stdout, as: UTF8.self) == "ready\n" && model.outputTruncated)

        // A late slice for the previous conversation never crosses over.
        model.bind(
            target: .init(endpointID: "origin#daemon-b", projectID: "project", conversationID: "next"), core: core)
        core.emit(.processes, scope: scope) {
            $0.processes = .with {
                $0.daemonID = "daemon-a"; $0.projectID = "project"; $0.cardID = "card"
                $0.processes = [self.execution("own")]
                $0.stdout = Data("old machine output".utf8)
            }
        }
        #expect(model.processes.isEmpty && model.stdout.isEmpty && model.selectedID == nil)
        #expect(model.running == 0 && !model.canStop)
    }

    @Test func hidingOnlyDeactivatesAndStopIsExplicit() async {
        let core = ScriptedCoreClient()
        let model = ConversationProcessesModel()
        model.bind(
            target: .init(endpointID: "origin#daemon-a", projectID: "project", conversationID: "card"), core: core)
        model.active = true
        await settle(model)
        let scope = sent(core)[0].scope
        core.emit(.processes, scope: scope) {
            $0.processes = .with {
                $0.daemonID = "daemon-a"; $0.projectID = "project"; $0.cardID = "card"
                $0.processes = [self.execution("own"), self.execution("done", status: "exited")]
                $0.selectedID = "own"
            }
        }
        model.active = false
        await settle(model)
        #expect(!sent(core).contains { if case .stop? = $0.action { true } else { false } }, "hiding never stops")
        guard case .bind(let hidden)? = sent(core).last?.action else { return }
        #expect(!hidden.active)

        await model.stopSelected()
        #expect(
            !sent(core).contains { if case .stop? = $0.action { true } else { false } }, "a hidden view cannot stop")
        model.active = true
        model.select("done")
        await model.stopSelected()
        #expect(
            !sent(core).contains { if case .stop? = $0.action { true } else { false } }, "only a running process stops")
        model.select("own")
        await model.stopSelected()
        #expect(sent(core).filter { if case .stop? = $0.action { true } else { false } }.count == 1)
    }

    @Test func releasingTheModelReleasesTheCoreSurface() async {
        let core = ScriptedCoreClient()
        var model: ConversationProcessesModel? = ConversationProcessesModel()
        model?.bind(
            target: .init(endpointID: "origin#daemon-a", projectID: "project", conversationID: "card"), core: core)
        model?.active = true
        await model?.refresh()
        let scope = sent(core)[0].scope
        #expect(core.isObserved(.processes, scope: scope))
        model = nil
        for _ in 0..<50 where core.isObserved(.processes, scope: scope) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!core.isObserved(.processes, scope: scope))
        #expect(!sent(core).contains { if case .stop? = $0.action { true } else { false } })
    }
}
