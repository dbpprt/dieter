import Foundation
import Testing
@testable import DieterMac

@Test func externalBrowserRulesMatchOnlyExplicitHostsAndPathSegments() throws {
    let rules = ["github.com", "*.signin.aws.amazon.com", "https://example.com/login"]
    #expect(ExternalBrowserRules.matches(try #require(URL(string: "https://github.com/org/repo")), entries: rules))
    #expect(
        ExternalBrowserRules.matches(try #require(URL(string: "https://us.signin.aws.amazon.com/")), entries: rules))
    #expect(
        ExternalBrowserRules.matches(try #require(URL(string: "https://example.com/login/callback")), entries: rules))
    #expect(!ExternalBrowserRules.matches(try #require(URL(string: "https://evilgithub.com/login")), entries: rules))
    #expect(!ExternalBrowserRules.matches(try #require(URL(string: "https://example.com/login-not")), entries: rules))
    #expect(!ExternalBrowserRules.matches(try #require(URL(string: "http://example.com/login")), entries: rules))
}

@Test func externalBrowserRulesRejectAmbiguousOrCredentialedInput() {
    #expect(ExternalBrowserRules.normalized("github.com") == "github.com")
    #expect(ExternalBrowserRules.normalized("*.signin.aws.amazon.com") == "*.signin.aws.amazon.com")
    #expect(ExternalBrowserRules.normalized("https://example.com/login") == "https://example.com/login")
    #expect(ExternalBrowserRules.normalized("https://user:secret@example.com") == nil)
    #expect(ExternalBrowserRules.normalized("https://example.com/login?token=secret") == nil)
    #expect(ExternalBrowserRules.normalized("github.com/path") == nil)
}
