import Foundation

// Never replace encoded reference frames. One explicit send-start token may
// admit one encode behind it; consumption retires only the exact frame. Legacy
// owners never send that token and retain the original one-credit behavior.
struct CaptureFrameCredits {
    struct Frame {
        let generation: UInt64
        let bytes: Int
        var overlapUntil: UInt64 = 0
    }
    static let maxAccessUnitBytes = 16 << 20
    private(set) var frames: [UInt64: Frame] = [:]
    var count: Int { frames.count }
    var retainedBytes: Int { frames.values.reduce(0) { $0 + $1.bytes } }

    mutating func produced(id: UInt64, generation: UInt64, bytes: Int) -> Bool {
        guard frames[id] == nil, frames.count < 2, bytes > 0, bytes <= Self.maxAccessUnitBytes else { return false }
        frames[id] = Frame(generation: generation, bytes: bytes)
        return true
    }
    mutating func sending(id: UInt64, generation: UInt64, now: UInt64, budgetMS: Int) {
        guard frames.count == 1, var frame = frames[id], frame.generation == generation,
            frame.overlapUntil == 0, frame.bytes <= 2 << 20, (1...50).contains(budgetMS) else { return }
        frame.overlapUntil = now + UInt64(budgetMS) * 1_000_000
        frames[id] = frame
    }
    @discardableResult mutating func consumed(id: UInt64, generation: UInt64?) -> Bool {
        guard let frame = frames[id], generation == nil || generation == frame.generation else { return false }
        frames.removeValue(forKey: id)
        return true
    }
    func canEncode(generation: UInt64, now: UInt64, frameAge: UInt64, encodeEstimate: UInt64) -> Bool {
        if frames.isEmpty { return true }
        guard frames.count == 1, let frame = frames.values.first, frame.generation == generation,
            frame.overlapUntil > now, frameAge <= 50_000_000 else { return false }
        return encodeEstimate < frame.overlapUntil - now && frameAge + encodeEstimate <= 50_000_000
    }
}
