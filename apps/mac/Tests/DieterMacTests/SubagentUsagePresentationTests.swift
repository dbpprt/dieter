import Testing
@testable import DieterMac

@Test func subagentUsageDistinguishesProcessedTokensFromCurrentContext() {
    let usage = SubagentUsagePresentation.resolve(tokens: 1_288_847, contextTokens: 128_953, contextWindow: 1_000_000)
    #expect(usage.metrics == ["1.3M processed", "129k / 1.0M context (13%)"])
}

@Test func subagentUsageOmitsUnavailableMeasurements() {
    #expect(SubagentUsagePresentation.resolve(tokens: 0, contextTokens: 0, contextWindow: 0).metrics.isEmpty)
    #expect(SubagentUsagePresentation.resolve(tokens: 1_200, contextTokens: 0, contextWindow: 0).metrics == ["1.2k processed"])
}
