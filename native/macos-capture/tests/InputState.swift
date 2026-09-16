import CoreGraphics
import Foundation

@main struct InputStateTest {
    static func main() throws {
        let input = InputInjector(bounds: CGRect(x: -1280, y: 0, width: 1280, height: 720), dryRun: true)
        var value = NativeInput(); value.kind = "key"; value.physicalKey = 4; value.generation = 1
        value.down = true; try input.handle(value)
        precondition(input.heldKeys == [0])
        value.down = false; try input.handle(value)
        precondition(input.heldKeys.isEmpty)
        for usage: UInt32 in [225, 229] {
            value.physicalKey = usage; value.down = true; value.modifiers = 1; try input.handle(value)
        }
        value.physicalKey = 225; value.down = false; try input.handle(value)
        precondition(input.heldKeys == [60])
        value.kind = "pointer_button"; value.button = 1; value.x = 0; value.y = 0; value.down = true
        try input.handle(value)
        precondition(input.position == CGPoint(x: -1280, y: 0))
        value.kind = "pointer_move"; value.x = 1_000_000; value.y = 1_000_000; try input.handle(value)
        precondition(input.position.x < 0 && input.position.y < 720 && input.heldButtons == [1])
        input.releaseAll()
        precondition(input.heldKeys.isEmpty && input.heldButtons.isEmpty)
        input.update(bounds: CGRect(x: 0, y: 0, width: 1600, height: 900), generation: 2)
        do { try input.handle(value); preconditionFailure("stale display accepted") } catch {}
        let first = InputInjector(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), dryRun: true)
        let second = InputInjector(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), dryRun: true)
        var held = NativeInput(); held.kind = "key"; held.physicalKey = 4; held.down = true; held.generation = 1
        try SharedInputAuthority.shared.handle(held, injector: first)
        SharedInputAuthority.shared.remove(second)
        precondition(first.heldKeys == [0], "Spectator teardown released the controller")
        try SharedInputAuthority.shared.handle(held, injector: second)
        precondition(first.heldKeys.isEmpty && second.heldKeys == [0], "Encoder move left held keys behind")
        held.kind = "release_all"
        try SharedInputAuthority.shared.handle(held, injector: first)
        precondition(second.heldKeys.isEmpty, "Handoff must release the machine's active injector")
        print(
            "Native input state: physical key zero, independent Shift sides, drag bounds, release and display generation passed"
        )
    }
}
