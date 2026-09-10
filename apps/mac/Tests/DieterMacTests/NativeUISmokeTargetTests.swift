#if DEBUG
    import AppKit
    import Testing
    @testable import DieterMac

    @Test @MainActor func recycledSmokeAnchorMovesToItsNewIdentifierWithoutRemovingOtherViews() {
        let originalFrames = NativeUISmokeTargets.frames
        NativeUISmokeTargets.frames = [:]
        defer { NativeUISmokeTargets.frames = originalFrames }

        let recycled = NSView()
        let other = NSView()
        NativeUISmokeTargets.register(recycled, identifier: "card.a")
        NativeUISmokeTargets.register(other, identifier: "card.a")

        NativeUISmokeTargets.register(recycled, identifier: "card.b")
        #expect(NativeUISmokeTargets.frames["card.a"]?.compactMap(\.view) == [other])
        #expect(NativeUISmokeTargets.frames["card.b"]?.compactMap(\.view) == [recycled])

        NativeUISmokeTargets.register(recycled, identifier: "card.b")
        #expect(NativeUISmokeTargets.frames["card.b"]?.compactMap(\.view) == [recycled])

        NativeUISmokeTargets.unregister(recycled)
        #expect(NativeUISmokeTargets.frames["card.b"] == nil)
        #expect(NativeUISmokeTargets.frames["card.a"]?.compactMap(\.view) == [other])
    }
#endif
