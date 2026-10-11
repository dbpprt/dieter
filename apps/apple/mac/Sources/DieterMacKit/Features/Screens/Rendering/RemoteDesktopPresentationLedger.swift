import Foundation

// Confined to the render executor. GPU completion releases GPU ownership;
// compositor presentation releases a different budget. Either callback can
// arrive first. Expiry only releases presentation accounting, never GPU work.
struct RemoteDesktopPresentationLedger {
    struct Entry: Sendable {
        let id: UInt64
        let token: UInt64
        let submittedAt: Double
        var gpuComplete = false
        var presentationComplete = false
    }
    var limit: Int
    private(set) var nextID: UInt64 = 0
    private(set) var entries: [UInt64: Entry] = [:]
    private(set) var gpuOwner: UInt64?
    var outstanding: Int { entries.values.filter { !$0.presentationComplete }.count }
    var canSubmit: Bool { gpuOwner == nil && outstanding < limit }

    mutating func begin(token: UInt64, at time: Double) -> UInt64? {
        guard canSubmit else { return nil }
        nextID &+= 1
        let id = nextID
        entries[id] = Entry(id: id, token: token, submittedAt: time)
        gpuOwner = id
        return id
    }
    mutating func completedGPU(_ id: UInt64) -> Bool {
        guard gpuOwner == id, var entry = entries[id] else { return false }
        gpuOwner = nil
        entry.gpuComplete = true
        entries[id] = entry
        collect(id)
        return true
    }
    mutating func presented(_ id: UInt64) -> Entry? {
        guard var entry = entries[id], !entry.presentationComplete else { return nil }
        entry.presentationComplete = true
        entries[id] = entry
        collect(id)
        return entry
    }
    mutating func expire(at now: Double, after timeout: Double = 0.1) -> Int {
        let expired = entries.values.filter { !$0.presentationComplete && now - $0.submittedAt >= timeout }.map(\.id)
        for id in expired { _ = presented(id) }
        return expired.count
    }
    mutating func invalidatePresentations() {
        for id in Array(entries.keys) { _ = presented(id) }
    }
    private mutating func collect(_ id: UInt64) {
        if let entry = entries[id], entry.gpuComplete && entry.presentationComplete { entries[id] = nil }
    }
}

// A strict one-presentation budget can halve cadence on compositors requiring
// two display intervals. Use one for sparse/idle updates, and two for sustained
// decoded motion. No predictive retirement: actual callbacks still own entries.
struct RemoteDesktopPresentationCadence {
    private var timestamp: Int32?
    private var arrivedAt: Double = 0
    private var consecutive = 0
    private var pipelineUntil: Double = 0
    mutating func observe(timestamp: Int32, at now: Double) {
        guard self.timestamp != timestamp else { return }
        let interval = now - arrivedAt
        consecutive = self.timestamp != nil && interval > 0 && interval <= 0.045 ? min(2, consecutive + 1) : 0
        if consecutive >= 2 { pipelineUntil = now + 0.1 }
        self.timestamp = timestamp; arrivedAt = now
    }
    func budget(at now: Double) -> Int { now < pipelineUntil ? 2 : 1 }
}

struct RemoteDesktopRenderTraceRecord: Codable, Sendable {
    let submission: UInt64
    let epoch: UInt64
    let rtpTimestamp: UInt32
    let decodedAt: Double
    let drawableRequestedAt: Double
    let drawableReadyAt: Double
    let committedAt: Double
    var gpuStartedAt: Double?
    var gpuCompletedAt: Double?
    var presentedAt: Double?
    var presentationCallbackAt: Double?
}

// Optional fixture diagnostics: numeric metadata only, no pixels/input text.
// 4096 slots stay below 1 MiB of record storage, independent of stream length.
final class RemoteDesktopRenderTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [RemoteDesktopRenderTraceRecord?]
    init(capacity: Int = ProcessInfo.processInfo.environment["DIETER_SCREEN_RENDER_TRACE"] == "1" ? 4096 : 0) {
        records = Array(repeating: nil, count: max(0, min(4096, capacity)))
    }
    func append(_ record: RemoteDesktopRenderTraceRecord) {
        lock.withLock {
            guard !records.isEmpty else { return }
            records[Int(record.submission % UInt64(records.count))] = record
        }
    }
    func update(_ id: UInt64, _ body: (inout RemoteDesktopRenderTraceRecord) -> Void) {
        lock.withLock {
            guard !records.isEmpty else { return }
            let index = Int(id % UInt64(records.count))
            guard var record = records[index], record.submission == id else { return }
            body(&record)
            records[index] = record
        }
    }
    var snapshot: [RemoteDesktopRenderTraceRecord] {
        lock.withLock { records.compactMap { $0 }.sorted { $0.submission < $1.submission } }
    }
}
