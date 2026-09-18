import Foundation

// Optional experiments retain the known-good envelope unless explicitly set.
// Window duration is a rate cap, not a buffering delay. Short windows need
// headroom so an ordinary IDR does not consume the entire average allowance.
struct EncoderBurstEnvelope {
    let seconds: Double
    let headroom: Double
    init(milliseconds: Int?) {
        if let milliseconds, [100, 250, 500].contains(milliseconds) {
            seconds = Double(milliseconds) / 1000
            headroom = 1.5
        } else {
            seconds = 1
            headroom = 1
        }
    }
    static var configured: Self {
        Self(milliseconds: ProcessInfo.processInfo.environment["DIETER_SCREEN_ENCODER_BURST_MS"].flatMap(Int.init))
    }
    func byteLimit(kbps: Int) -> Int { max(1, Int(Double(kbps) * 125 * seconds * headroom)) }
    func values(kbps: Int) -> CFArray { [byteLimit(kbps: kbps), seconds] as CFArray }
    func apply(kbps: Int, setProperty: (CFArray) -> Int32) -> String {
        let requested = setProperty(values(kbps: kbps))
        if requested == 0 { return "burst=\(seconds)s; headroom=\(headroom)" }
        // This property is optional. Rejecting both envelopes must preserve
        // ordinary real-time encoding, as older helpers did without a cap.
        if seconds != 1 {
            let fallback = setProperty(Self(milliseconds: nil).values(kbps: kbps))
            if fallback == 0 { return "burst=1.0s; headroom=1.0; burstFallback=\(requested)" }
            return "burst=unsupported; burstRejected=\(requested); burstFallbackRejected=\(fallback)"
        }
        return "burst=unsupported; burstRejected=\(requested)"
    }
}

// One coordinated episode: useful LTR can be retried sooner on a LAN, but
// repeated feedback cannot force an IDR storm. Time is injected for tests.
struct CaptureRecoverySchedule {
    private(set) var lastAttempt: UInt64 = 0
    private(set) var lastKeyframe: UInt64 = 0
    private(set) var referenceDeadline: UInt64?
    private(set) var referenceWindowMS = 200
    private var referenceWasProduced = false
    mutating func request(now: UInt64, windowMS: Int, referenceAvailable: Bool, pending: Bool) -> Bool? {
        let window = UInt64(min(250, max(50, windowMS))) * 1_000_000
        guard lastAttempt == 0 || now >= lastAttempt && now - lastAttempt >= window else { return nil }
        let reference = referenceAvailable && !pending
        if !reference && lastKeyframe != 0 && (now < lastKeyframe || now - lastKeyframe < 200_000_000) { return nil }
        lastAttempt = now
        if !reference { lastKeyframe = now }
        referenceWindowMS = min(250, max(50, windowMS))
        referenceWasProduced = false
        referenceDeadline = reference ? max(now + window, lastKeyframe + 200_000_000) : nil
        return reference
    }
    mutating func acknowledgeRecovery() { referenceDeadline = nil }
    mutating func producedReference(now: UInt64) -> Bool {
        guard referenceDeadline != nil, !referenceWasProduced else { return false }
        referenceWasProduced = true
        // Admission/encode time must not consume the receiver's ACK budget.
        // This transition can extend it once, only for an actual encoded LTR.
        referenceDeadline = max(now + UInt64(referenceWindowMS) * 1_000_000, lastKeyframe + 200_000_000)
        return true
    }
    mutating func expireReference(now: UInt64) -> Bool {
        guard let deadline = referenceDeadline, now >= deadline else { return false }
        referenceDeadline = nil
        return true
    }
}
