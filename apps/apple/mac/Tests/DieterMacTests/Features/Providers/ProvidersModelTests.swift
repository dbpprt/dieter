import DieterClientAPI
import Testing

@testable import DieterMacKit

/// The Providers model over a scripted core: the slice is observed only while
/// shown, every command carries exactly what the user chose, and the sign-in
/// sheet follows the session the core started.
@MainActor
struct ProvidersModelTests {
    private static func slice(accounts: [ClientProviderAccountRow] = [], sessions: [ClientProviderSignInSession] = [])
        -> ClientProvidersSlice
    {
        .with {
            $0.groups = [
                .with {
                    $0.provider = "claude"
                    $0.providerName = "Claude"
                    $0.accounts = accounts
                },
                .with {
                    $0.provider = "chatgpt"
                    $0.providerName = "ChatGPT"
                },
            ]
            $0.sessions = sessions
        }
    }

    private static func account(_ id: String, _ label: String) -> ClientProviderAccountRow {
        .with {
            $0.id = id
            $0.label = label
        }
    }

    @Test func theProvidersSliceIsObservedOnlyWhileAViewShowsIt() {
        let core = ScriptedCoreClient()
        let model = ProvidersModel()
        model.core = core
        model.observe()
        model.observe()
        #expect(core.isObserved(.providers))
        core.emit(.providers) {
            $0.providers = Self.slice(accounts: [Self.account("pa_work", "Work")])
            $0.providers.mutating = ["pa_work"]
            $0.providers.summary = .with { $0.text = "62% left" }
        }
        #expect(model.groups.map(\.provider) == ["claude", "chatgpt"])
        #expect(model.account("pa_work")?.label == "Work" && model.hasAccounts)
        #expect(model.isMutating("pa_work") && model.summary.text == "62% left")
        model.release()
        #expect(core.isObserved(.providers), "another view still shows it")
        model.release()
        #expect(!core.isObserved(.providers))
    }

    @Test func accountWideChangesCarryTheAccountAndWhatWasChosen() async {
        let core = ScriptedCoreClient()
        let model = ProvidersModel()
        model.core = core
        core.handler = { command in
            switch command.providers.action {
            case .create: .with { $0.providerAccount = .with { $0.accountID = "pa_new" } }
            case .consumeReset:
                .with {
                    $0.providerReset = .with {
                        $0.accountID = "pa_personal"
                        $0.outcome = "reset"
                        $0.message = "Usage limits were reset."
                    }
                }
            default: .with { $0.done = ClientDone() }
            }
        }

        let created = await model.create(provider: "chatgpt", label: "Personal", method: "codex")
        #expect(created == "pa_new")
        let create = core.commands.last?.providers.create
        #expect(create?.provider == "chatgpt" && create?.label == "Personal" && create?.method == "codex")

        #expect(await model.rename(accountID: "pa_new", label: "Home"))
        #expect(core.commands.last?.providers.rename.accountID == "pa_new")
        #expect(core.commands.last?.providers.rename.label == "Home")
        await model.setDefault(accountID: "pa_new")
        #expect(core.commands.last?.providers.setDefault.accountID == "pa_new")
        await model.setIncluded(accountID: "pa_new", included: false)
        #expect(core.commands.last?.providers.setIncluded.accountID == "pa_new")
        #expect(core.commands.last?.providers.setIncluded.included == false)
        await model.setOmpAccess(accountID: "pa_new", allowed: true)
        #expect(core.commands.last?.providers.setOmpAccess.accountID == "pa_new")
        #expect(core.commands.last?.providers.setOmpAccess.allowed == true)
        await model.refreshUsage(accountID: "pa_new")
        #expect(core.commands.last?.providers.refreshUsage.accountID == "pa_new")
        await model.signOut(accountID: "pa_new", daemonID: "d_box")
        #expect(core.commands.last?.providers.signOut.daemonID == "d_box")
        await model.check(accountID: "pa_new", daemonID: "d_box")
        #expect(core.commands.last?.providers.check.accountID == "pa_new")
        let outcome = await model.consumeReset(accountID: "pa_personal")
        #expect(outcome?.message == "Usage limits were reset.")
        #expect(core.commands.last?.providers.consumeReset.accountID == "pa_personal")
        #expect(await model.remove(accountID: "pa_new"))
        #expect(core.commands.last?.providers.remove.accountID == "pa_new")
        #expect(model.failure == nil && !model.working)
    }

    @Test func aRefusedCommandShowsTheCoresReason() async {
        let core = ScriptedCoreClient()
        let model = ProvidersModel()
        model.core = core
        core.handler = { _ in throw CoreFailure(kind: .invalid, message: "Choose Claude or ChatGPT.") }
        #expect(await model.create(provider: "gemini", label: "X") == nil)
        #expect(model.failure == "Choose Claude or ChatGPT." && model.problem == "Choose Claude or ChatGPT.")
        #expect(!model.working)
        core.handler = { _ in .with { $0.done = ClientDone() } }
        await model.setDefault(accountID: "pa_work")
        #expect(model.failure == nil, "the next command clears it")
    }

    @Test func addingAnAccountSignsItInOnceItReachesTheReplica() async {
        let core = ScriptedCoreClient()
        let model = ProvidersModel()
        model.core = core
        model.arrivalTimeout = .seconds(5)
        core.handler = { command in
            switch command.providers.action {
            case .create:
                // The account replica delivers the new record after the create.
                Task { @MainActor in
                    core.emit(.providers) {
                        $0.providers = Self.slice(accounts: [Self.account("pa_scratch", "Scratch")])
                    }
                }
                return .with { $0.providerAccount = .with { $0.accountID = "pa_scratch" } }
            case .signIn:
                return .with { $0.providerSignIn = .with { $0.sessionID = "signin_1" } }
            default:
                return .with { $0.done = ClientDone() }
            }
        }
        model.observe()
        core.emit(.providers) { $0.providers = Self.slice() }

        let added = await model.add(provider: "claude", label: "Scratch", method: "", daemonID: "d_box")
        #expect(added == ProvidersModel.AddedAccount(accountID: "pa_scratch", sessionID: "signin_1"))
        let signIn = core.commands.last?.providers.signIn
        #expect(signIn?.accountID == "pa_scratch" && signIn?.daemonID == "d_box" && signIn?.flow == "")
        #expect(model.presentedSessionID == nil, "the add sheet shows the sign-in itself")
        model.release()
        #expect(!core.isObserved(.providers), "waiting for the account held the slice only meanwhile")
    }

    @Test func anAccountThatDoesNotArriveIsKeptWithoutASignIn() async {
        let core = ScriptedCoreClient()
        let model = ProvidersModel()
        model.core = core
        model.arrivalTimeout = .milliseconds(250)
        core.handler = { _ in .with { $0.providerAccount = .with { $0.accountID = "pa_late" } } }

        let added = await model.add(provider: "claude", label: "Late", method: "", daemonID: "d_box")
        #expect(added == ProvidersModel.AddedAccount(accountID: "pa_late", sessionID: nil))
        #expect(core.commands.count == 1, "no sign-in starts for an account the core cannot see yet")
        #expect(model.failure?.contains("Late was added") == true)

        // Without a machine there is nothing to wait for.
        let later = await model.add(provider: "claude", label: "Later", method: "", daemonID: "")
        #expect(later?.sessionID == nil && core.commands.count == 2)
    }

    @Test func theSignInSheetFollowsTheSessionTheCoreStarted() async {
        let core = ScriptedCoreClient()
        let model = ProvidersModel()
        model.core = core
        var next = 0
        core.handler = { command in
            switch command.providers.action {
            case .signIn, .signInAll:
                next += 1
                return .with { $0.providerSignIn = .with { $0.sessionID = "signin_\(next)" } }
            default:
                return .with { $0.done = ClientDone() }
            }
        }

        await model.presentSignIn(accountID: "pa_work", daemonID: "d_box")
        #expect(model.presentedSessionID == "signin_1")

        await model.submit(sessionID: "signin_1", code: "FIXTURE-CODE")
        let code = core.commands.last?.providers.submit
        #expect(code?.sessionID == "signin_1" && code?.code == "FIXTURE-CODE")
        await model.submit(sessionID: "signin_1", callbackURL: "http://localhost:54545/callback?code=x")
        #expect(core.commands.last?.providers.submit.callbackURL == "http://localhost:54545/callback?code=x")

        // Another sheet replaces the shown one, which the core then drops.
        await model.presentSignInAll(accountID: "pa_work")
        #expect(model.presentedSessionID == "signin_2")
        #expect(core.commands.last?.providers.signInAll.accountID == "pa_work")
        await Task.yield()
        await Task.yield()
        #expect(core.commands.contains { $0.providers.dismiss.sessionID == "signin_1" })

        await model.cancel(sessionID: "signin_2")
        #expect(core.commands.last?.providers.cancel.sessionID == "signin_2")
        await model.close(sessionID: "signin_2")
        #expect(model.presentedSessionID == nil)
        #expect(core.commands.last?.providers.dismiss.sessionID == "signin_2")

        // Dismissing a session the core already dropped is no failure.
        core.handler = { _ in throw CoreFailure(kind: .permanent, message: "This sign-in is no longer open.") }
        await model.dismiss(sessionID: "signin_2")
        #expect(model.failure == nil)
    }

    @Test func theSheetOpensTheLoopbackPageOnlyOnTheSigningMachine() {
        var session = ClientProviderSignInSession.with {
            $0.phase = "waiting"
            $0.openURL = "https://claude.ai/oauth/authorize?x=1"
            $0.localURL = "http://localhost:54545/start"
        }
        #expect(session.pageURL?.absoluteString == "https://claude.ai/oauth/authorize?x=1")
        session.sameHost = true
        #expect(session.pageURL?.absoluteString == "http://localhost:54545/start")
        #expect(session.isLive && session.acceptsInput)
        session.phase = "starting"
        #expect(session.isLive && !session.acceptsInput, "the machine is not ready for a code yet")
        for finished in ["succeeded", "failed", "canceled"] {
            session.phase = finished
            #expect(!session.isLive && !session.acceptsInput)
        }
        #expect(ClientProviderSignInSession().pageURL == nil)
    }

    @Test func accountOptionsSayWhyTheyCannotRun() {
        let ready = ClientAgentAccountOption.with {
            $0.id = "pa_work"; $0.label = "Work"; $0.detail = "alice@corp.com · Max"; $0.ready = true
        }
        let blocked = ClientAgentAccountOption.with {
            $0.id = "pa_home"; $0.label = "Home"; $0.detail = "bob@home.com"; $0.reason = "Not signed in on box"
        }
        #expect(AccountOptionText.title(ready) == "Work · alice@corp.com · Max")
        #expect(AccountOptionText.title(blocked) == "Home · Not signed in on box")
        #expect(
            AccountOptionText.title(
                .with {
                    $0.label = "Bare"; $0.ready = true
                }) == "Bare")
    }
}
