import DieterClientAPI

/// The host cursor as the core reports it: whether it shows, where (normalized
/// to the shared display), and its image's size and hotspot in host points.
public struct ScreenCursorState: Equatable, Sendable {
    public var visible = false
    public var x = 0.5
    public var y = 0.5
    public var width = 0.0
    public var height = 0.0
    public var hotspotX = 0.0
    public var hotspotY = 0.0

    public init() {}

    public init(_ slice: ClientScreenSlice) {
        visible = slice.cursorVisible
        x = slice.cursorX
        y = slice.cursorY
        width = slice.cursorWidth
        height = slice.cursorHeight
        hotspotX = slice.cursorHotspotX
        hotspotY = slice.cursorHotspotY
    }
}
