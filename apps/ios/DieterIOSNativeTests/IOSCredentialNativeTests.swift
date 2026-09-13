import DieterClient
import DieterCore
import Foundation
import Security
import XCTest

/// Runs in the iOS application test host. Every query names one newly
/// generated account; no test enumerates, reads, or deletes existing sessions.
@MainActor
final class IOSCredentialNativeTests: XCTestCase {
    func testProductionFacadePersistsUpdatesAndRemovesOnlyItsGateway() async throws {
        let host = "keychain-\(UUID().uuidString.lowercased()).invalid"
        let origin = DieterEndpoint(name: "Test", host: host, port: 443, secure: true)
        let other = DieterEndpoint(name: "Other", host: host, port: 8443, secure: true)
        addTeardownBlock {
            try await DieterCredentialStore.remove(for: origin)
            try await DieterCredentialStore.remove(for: other)
        }
        let missing = await DieterCredentialStore.token(for: origin)
        XCTAssertNil(missing)
        try await DieterCredentialStore.save("first-test-token", for: origin)
        try await DieterCredentialStore.save("separate-test-token", for: other)
        try await DieterCredentialStore.save("updated-test-token", for: origin)

        // A separate actor must retrieve the value written through the iOS
        // production facade, proving its real backend is Keychain.
        let reader = DieterCredentialKeychainStore()
        let reloaded = await reader.token(for: origin.credentialID)
        XCTAssertEqual(reloaded, "updated-test-token")
        try await DieterCredentialStore.remove(for: origin)
        try await DieterCredentialStore.remove(for: origin)
        let removed = await DieterCredentialStore.token(for: origin)
        let untouched = await DieterCredentialStore.token(for: other)
        XCTAssertNil(removed)
        XCTAssertEqual(untouched, "separate-test-token")
    }

    func testStoredSessionIsDeviceLocalAndAvailableAfterFirstUnlock() async throws {
        let service = "com.dbpprt.dieter.ios.native-tests.\(UUID().uuidString)"
        let account = "https://\(UUID().uuidString.lowercased()).invalid:443"
        let storage = DieterCredentialKeychainStore(service: service)
        addTeardownBlock { try await storage.remove(for: account) }
        try await storage.save("isolated-test-token", for: account)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testCanceledCredentialWritePreservesThePreviousToken() async throws {
        let service = "com.dbpprt.dieter.ios.native-tests.\(UUID().uuidString)"
        let account = "https://\(UUID().uuidString.lowercased()).invalid:443"
        let storage = DieterCredentialKeychainStore(service: service)
        addTeardownBlock { try await storage.remove(for: account) }
        try await storage.save("existing-test-token", for: account)
        // This task inherits the main actor and cannot begin until this method
        // yields, so cancellation happens before entering the Keychain actor.
        let writer = Task { try await storage.save("must-not-be-saved", for: account) }
        writer.cancel()
        do {
            try await writer.value
            XCTFail("A canceled sign-in must not replace a saved session")
        } catch is CancellationError {
        }
        let retained = await storage.token(for: account)
        XCTAssertEqual(retained, "existing-test-token")
    }
}
