import CoreGraphics

/// Where the transcript's viewport rests relative to its end; native
/// scroll behaviour only.
enum IOSConversationScrollBehavior {
    static let bottomID = "ios.conversation.bottom"
    private static let latestTolerance: CGFloat = 2
    static let jumpToLatestThreshold: CGFloat = 96

    static func isAtLatest(visibleMaxY: CGFloat, contentHeight: CGFloat, bottomInset: CGFloat = 0) -> Bool {
        visibleMaxY - bottomInset >= contentHeight - latestTolerance
    }

    static func distanceFromLatest(visibleMaxY: CGFloat, contentHeight: CGFloat, bottomInset: CGFloat = 0)
        -> CGFloat
    {
        max(0, contentHeight - (visibleMaxY - bottomInset))
    }

    static func shouldShowJumpToLatest(visibleMaxY: CGFloat, contentHeight: CGFloat, bottomInset: CGFloat = 0)
        -> Bool
    {
        distanceFromLatest(visibleMaxY: visibleMaxY, contentHeight: contentHeight, bottomInset: bottomInset)
            >= jumpToLatestThreshold
    }
}
