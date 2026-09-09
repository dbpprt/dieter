import Foundation
import Testing
@testable import DieterMac

private actor AuthenticationDeadline {
    private var continuation: CheckedContinuation<Void, Never>?
    var ready: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func expire() { continuation?.resume(); continuation = nil }
}

@Test @MainActor func signInCancellationAllowsRetryAndIgnoresLateCallbacks() async throws {
    let environment = DieterAppEnvironment.testing()
    var opened = 0
    let auth = DieterAuthentication(
        defaults: environment.defaults, credentials: environment.credentials,
        openBrowser: { _ in
            opened += 1; return true
        })
    let endpoint = try #require(DieterEndpoint.parse("https://example.test", name: "Fixture"))
    let first = Task { try await auth.signIn(to: endpoint) }
    while opened == 0 { await Task.yield() }
    first.cancel()
    do { _ = try await first.value; Issue.record("Cancelled sign-in succeeded") } catch is CancellationError {} catch {
        Issue.record(error)
    }
    #expect(!auth.complete(url: URL(string: "dieter-mac://oauth/callback?code=late")!))
    let second = Task { try await auth.signIn(to: endpoint) }
    while opened < 2 { await Task.yield() }
    auth.cancel()
    do { _ = try await second.value; Issue.record("Cancelled retry succeeded") } catch is CancellationError {} catch {
        Issue.record(error)
    }
    #expect(environment.defaults.data(forKey: "DieterPendingAuthentication") == nil)
    #expect(await environment.credentials.token(for: endpoint.credentialID) == nil)
}

@Test @MainActor func signInDeadlineReleasesPendingAttempt() async throws {
    let environment = DieterAppEnvironment.testing(), deadline = AuthenticationDeadline()
    let auth = DieterAuthentication(
        defaults: environment.defaults, credentials: environment.credentials,
        clock: ClientClock(now: { Date() }, sleep: { _ in await deadline.wait() }),
        openBrowser: { _ in true })
    let endpoint = try #require(DieterEndpoint.parse("https://example.test", name: "Fixture"))
    let task = Task { try await auth.signIn(to: endpoint) }
    while !(await deadline.ready) { await Task.yield() }
    await deadline.expire()
    do { _ = try await task.value; Issue.record("Expired sign-in succeeded") } catch {
        #expect(error as? DieterAuthenticationError == .timedOut)
    }
    #expect(environment.defaults.data(forKey: "DieterPendingAuthentication") == nil)
}

@Test func credentialRemovalReportsCorruptPersistenceInsteadOfPretendingToSignOut() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("corrupt".utf8).write(to: root)
    let credentials = DieterCredentialFileStore(fileURL: root)
    do {
        try await credentials.remove(for: "fixture"); Issue.record("Corrupt credentials were silently accepted")
    } catch { #expect(try Data(contentsOf: root) == Data("corrupt".utf8)) }
}
