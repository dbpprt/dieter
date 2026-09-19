import Testing
@testable import DieterIOS

@Suite("iOS conversation scroll behavior")
struct IOSConversationScrollBehaviorTests {
    @Test func jumpToLatestRequiresMeaningfulDistanceFromTheBottom() {
        #expect(
            !IOSConversationScrollBehavior.shouldShowJumpToLatest(
                visibleMaxY: 1_120, contentHeight: 1_000, bottomInset: 120))
        #expect(
            !IOSConversationScrollBehavior.shouldShowJumpToLatest(
                visibleMaxY: 1_025, contentHeight: 1_000, bottomInset: 120))
        #expect(
            IOSConversationScrollBehavior.shouldShowJumpToLatest(
                visibleMaxY: 1_024, contentHeight: 1_000, bottomInset: 120))
    }
}
