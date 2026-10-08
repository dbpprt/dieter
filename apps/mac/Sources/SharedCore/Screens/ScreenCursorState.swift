import DieterAPI

/// The host cursor as the core reports it: whether it shows, where (normalized
/// to the shared display), and its image's size and hotspot in host points.
package struct ScreenCursorState: Equatable, Sendable {
    package var visible = false
    package var x = 0.5
    package var y = 0.5
    package var width = 0.0
    package var height = 0.0
    package var hotspotX = 0.0
    package var hotspotY = 0.0

    package init() {}

    package init(_ slice: ClientScreenSlice) {
        visible = slice.cursorVisible
        x = slice.cursorX
        y = slice.cursorY
        width = slice.cursorWidth
        height = slice.cursorHeight
        hotspotX = slice.cursorHotspotX
        hotspotY = slice.cursorHotspotY
    }
}
