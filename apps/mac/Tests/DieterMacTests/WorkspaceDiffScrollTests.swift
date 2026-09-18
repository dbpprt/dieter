import Testing
@testable import DieterMac

@Test @MainActor func diffHorizontalScrollStateIgnoresSubpixelLayoutNoise() {
    let state = DiffHorizontalScrollState()
    state.update(0.2)
    #expect(state.offset == 0)
    state.update(8)
    #expect(state.offset == 8)
    state.update(8.1)
    #expect(state.offset == 8)
    state.update(8.5)
    #expect(state.offset == 8.5)
}
