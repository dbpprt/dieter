import DieterAPI
import Testing
@testable import DieterMac

@Test func taskTokenUsageDistinguishesMissingAndPartialReports() {
    var usage = Dieter_V1_TokenUsage()
    usage.missingMessages = 1
    usage.partial = true
    #expect(TaskTokenUsagePresentation.label(usage) == "Tokens unavailable")
    usage.reportedMessages = 2
    usage.totalTokens = 1250
    usage.inputTokens = 1000
    usage.outputTokens = 250
    #expect(TaskTokenUsagePresentation.label(usage).contains("partial"))
    #expect(TaskTokenUsagePresentation.detail(usage).contains("input"))
    usage.partial = false
    #expect(!TaskTokenUsagePresentation.label(usage).contains("partial"))
}
