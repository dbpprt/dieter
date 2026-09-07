import DieterAPI
import Foundation
import Testing

@Test func cardDecodesDeployedWorkspaceRemoteFieldsWithoutTreatingThemAsUsage() throws {
    // Card fields 33 and 34 in deployed private builds are strings.
    let wire = Data([0x8a, 0x02, 6] + Array("origin".utf8) + [0x92, 0x02, 6] + Array("manual".utf8))
    let card = try Dieter_V1_Card(serializedBytes: wire)
    #expect(!card.hasTokenUsage)
    var updated = card
    updated.tokenUsage.totalTokens = 125
    updated.tokenUsage.reportedMessages = 1
    let decoded = try Dieter_V1_Card(serializedBytes: updated.serializedData())
    #expect(decoded.tokenUsage.totalTokens == 125)
    #expect(decoded.unknownFields == card.unknownFields)
}
