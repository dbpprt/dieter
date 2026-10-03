import Foundation
import SharedCore
import Testing

@Test func sleepConversionSaturatesWithoutTrapping() {
    #expect(DieterTaskSleep.nanoseconds(seconds: .nan) == 0)
    #expect(DieterTaskSleep.nanoseconds(seconds: -.infinity) == 0)
    #expect(DieterTaskSleep.nanoseconds(seconds: -1) == 0)
    #expect(DieterTaskSleep.nanoseconds(seconds: 0) == 0)
    #expect(DieterTaskSleep.nanoseconds(seconds: 0.125) == 125_000_000)
    #expect(DieterTaskSleep.nanoseconds(seconds: .infinity) == .max)
    #expect(DieterTaskSleep.nanoseconds(seconds: Double(UInt64.max)) == .max)
    #expect(DieterTaskSleep.nanoseconds(duration: .seconds(Int64.max)) == .max)
    #expect(DieterTaskSleep.nanoseconds(duration: .seconds(-1)) == 0)
    #expect(DieterTaskSleep.nanoseconds(duration: .seconds(1) - .nanoseconds(1)) == 999_999_999)
    #expect(DieterTaskSleep.nanoseconds(duration: .seconds(18_446_744_073) + .nanoseconds(709_551_615)) == .max)
    #expect(DieterTaskSleep.nanoseconds(duration: .seconds(18_446_744_073) + .nanoseconds(709_551_616)) == .max)
}

@Test func canceledZeroDelayHonorsCancellation() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await DieterTaskSleep.duration(.zero)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}
