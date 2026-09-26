import AppKit
import DieterAPI
import Foundation
import GRPCCore
import OSLog
import Observation
import UniformTypeIdentifiers
import UserNotifications

// Match iOS: conversation reads are large enough that a scrollback boundary
// reveals a useful stretch of context instead of one short turn.
let conversationPageSize: Int32 = 60
let schedulePageSize: Int32 = 50
let syncConversationMessageLimit: Int32 = 30
let syncRecentConversationLimit: Int32 = 8
let cachedConversationLimit = 24
let terminalClientBufferLimit = 2 * 1_024 * 1_024
let outboxLogger = Logger(subsystem: "com.dbpprt.dieter.mac", category: "Outbox")
let connectionLogger = Logger(subsystem: "com.dbpprt.dieter.mac", category: "Connection")
let syncPerformanceLog = OSLog(subsystem: "com.dbpprt.dieter.mac", category: "SyncPerformance")

struct TerminalScreenState: Equatable, Sendable {
    private(set) var chunks: [Data] = []
    private(set) var byteCount = 0
    var revision = 0
    var resetRevision = 0

    /// Compatibility accessor for persistence fixtures and diagnostics. The
    /// live renderer consumes `chunks` directly so normal terminal updates do
    /// not flatten and recopy the retained replay buffer.
    var data: Data {
        get {
            guard chunks.count != 1 else { return chunks[0] }
            return chunks.reduce(into: Data(capacity: byteCount)) { $0.append($1) }
        }
        set {
            chunks = newValue.isEmpty ? [] : [newValue]
            byteCount = newValue.count
        }
    }

    mutating func replace(with data: Data) {
        chunks = data.isEmpty ? [] : Self.chunked(data)
        byteCount = data.count
    }

    @discardableResult
    mutating func append(_ data: Data, limit: Int) -> Bool {
        guard !data.isEmpty else { return false }
        var remaining = data[...]
        if var tail = chunks.last, tail.count < Self.chunkSize {
            chunks.removeLast()
            let count = min(Self.chunkSize - tail.count, remaining.count)
            tail.append(contentsOf: remaining.prefix(count))
            chunks.append(tail)
            remaining = remaining.dropFirst(count)
        }
        while !remaining.isEmpty {
            let count = min(Self.chunkSize, remaining.count)
            chunks.append(Data(remaining.prefix(count)))
            remaining = remaining.dropFirst(count)
        }
        byteCount += data.count
        return trim(to: limit)
    }

    private mutating func trim(to limit: Int) -> Bool {
        guard byteCount > limit else { return false }
        var discard = byteCount - max(0, limit)
        while let first = chunks.first, discard >= first.count {
            discard -= first.count
            chunks.removeFirst()
        }
        if discard > 0, let first = chunks.first {
            chunks[0] = Data(first.dropFirst(discard))
        }
        byteCount = max(0, limit)
        return true
    }

    private static let chunkSize = 64 * 1_024

    private static func chunked(_ data: Data) -> [Data] {
        stride(from: 0, to: data.count, by: chunkSize).map { offset in
            Data(data[offset..<min(data.count, offset + chunkSize)])
        }
    }
}

enum TerminalScreenReducer {
    static func applying(
        data: Data,
        screenReset: Bool,
        to current: TerminalScreenState,
        limit: Int = terminalClientBufferLimit
    ) -> TerminalScreenState {
        var result = current
        if screenReset {
            result.replace(with: data)
            result.resetRevision += 1
        } else {
            if result.append(data, limit: limit) { result.resetRevision += 1 }
        }
        if screenReset, result.byteCount > limit {
            result.data = Data(result.data.suffix(limit))
            result.resetRevision += 1
        }
        result.revision += 1
        return result
    }
}

enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case inbox = "Inbox"
    case board = "Board"
    case chats = "All chats"
    case terminals = "Terminals"
    case screens = "Screens"
    case files = "Files"
    case changes = "Changes"
    case schedules = "Schedules"
    case archive = "Archive"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .board: "rectangle.split.3x1"
        case .chats: "bubble.left.and.bubble.right"
        case .terminals: "terminal"
        case .screens: "rectangle.inset.filled.and.person.filled"
        case .files: "doc.on.doc"
        case .changes: "arrow.triangle.branch"
        case .schedules: "calendar.badge.clock"
        case .archive: "archivebox"
        case .settings: "gearshape"
        }
    }
}

enum DieterStoreConnectionError: LocalizedError {
    case incompatible(found: String)
    case syncEnded
    case syncTimedOut

    var errorDescription: String? {
        switch self {
        case .incompatible(let found):
            "Dieter update required · minimum release \(found.isEmpty ? "unknown" : found)."
        case .syncEnded:
            "Live updates stopped unexpectedly."
        case .syncTimedOut:
            "Live updates stopped responding."
        }
    }
}

enum SyncStreamLiveness {
    static let timeout: TimeInterval = 45

    static func requiresConnectionRecovery(lastFrameAt: Date?, now: Date = Date()) -> Bool {
        guard let lastFrameAt else { return true }
        return now.timeIntervalSince(lastFrameAt) >= timeout
    }
}

enum ConnectionAttemptOwnership {
    static func mayMutateSharedState(attemptGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        attemptGeneration == currentGeneration
    }
}

enum MachineCompatibility: Equatable, Sendable {
    case compatible
    case incompatible
}

extension DieterEndpoint {
    var compatibilityState: MachineCompatibility {
        guard daemonID != nil else { return .compatible }
        return compatibility == .compatible ? .compatible : .incompatible
    }

    var incompatibilityDescription: String? {
        guard compatibilityState == .incompatible else { return nil }
        return
            "Update required · Dieter \(releaseVersion.isEmpty ? "unknown" : releaseVersion) (requires \(minimumReleaseVersion.isEmpty ? "a newer release" : minimumReleaseVersion))"
    }
}

enum OutboxWorkerOwnership {
    static func mayClearTask(workerGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        workerGeneration == currentGeneration
    }
}

enum SyncFreshnessPresentation {
    static func lastConnectedLabel(lastConnectedAt: Date?, now: Date = Date()) -> String {
        guard let lastConnectedAt else { return "Last connected unknown" }
        return relativeLabel(prefix: "Last connected", date: lastConnectedAt, now: now)
    }

    static func lastUpdateLabel(lastUpdatedAt: Date?, now: Date = Date()) -> String {
        guard let lastUpdatedAt else { return "Not updated yet" }
        return relativeLabel(prefix: "Updated", date: lastUpdatedAt, now: now)
    }

    private static func relativeLabel(prefix: String, date: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        switch elapsed {
        case ..<60:
            return "\(prefix) just now"
        case ..<3_600:
            return "\(prefix) \(max(1, Int(elapsed / 60)))m ago"
        case ..<86_400:
            return "\(prefix) \(max(1, Int(elapsed / 3_600)))h ago"
        default:
            return "\(prefix) \(max(1, Int(elapsed / 86_400)))d ago"
        }
    }
}

enum WorkspaceFreshnessState: Equatable {
    case live
    case syncing
    case reconnecting
    case offline

    static func resolve(
        phase: ConnectionPhase,
        globalSyncing: Bool,
        hasCachedWorkspace: Bool
    ) -> Self {
        if phase.isConnected { return globalSyncing ? .syncing : .live }
        if phase == .connecting, hasCachedWorkspace { return .reconnecting }
        return .offline
    }

    var isLive: Bool { self == .live }

    var label: String {
        switch self {
        case .live: "Online"
        case .syncing: "Syncing"
        case .reconnecting: "Reconnecting"
        case .offline: "Offline"
        }
    }
}

enum SyncCursorPersistencePolicy {
    // A five-minute checkpoint keeps a 4 MiB projection below 50 MiB of
    // logical writes per hour. Deactivation and durability-sensitive outbox
    // mutations explicitly flush sooner.
    static let interval: TimeInterval = 5 * 60

    static func shouldPersist(projectionChanged: Bool, lastPersistedAt: Date?, now: Date) -> Bool {
        // The in-memory snapshot and cursor advance together. Persisting an
        // older pair is safe because WatchSync will replay the later delta, so
        // high-frequency conversation frames do not need a multi-megabyte
        // atomic disk write each time.
        guard projectionChanged else { return false }
        return lastPersistedAt.map { now.timeIntervalSince($0) >= interval } ?? true
    }
}

struct MachineOutboxSummary: Equatable, Sendable {
    let messageCount: Int
    let changeCount: Int
    let retrying: Bool
    let failed: Bool
    let failureMessage: String?

    var itemCount: Int { messageCount + changeCount }
    var storageBlocked: Bool { DieterRPCFailure.isInsufficientStorage(failureMessage) }

    var queuedLabel: String {
        let noun: String
        if changeCount == 0 {
            noun = messageCount == 1 ? "message" : "messages"
        } else if messageCount == 0 {
            noun = changeCount == 1 ? "change" : "changes"
        } else {
            noun = itemCount == 1 ? "item" : "items"
        }
        return "\(itemCount) \(noun) queued"
    }

    var deliveryLabel: String {
        let suffix =
            failed
            ? "needs attention."
            : storageBlocked
                ? "free disk space on this machine; retries automatically every minute."
                : "delivers when it reconnects."
        return "\(queuedLabel) — \(suffix)"
    }

    func toastPhase(machineOnline: Bool) -> MachineDeliveryToastPhase {
        if failed { return .failed }
        if storageBlocked { return .waitingForStorage }
        if retrying { return .retrying }
        return machineOnline ? .sending : .waiting
    }

    static func summaries(for entries: [DieterOutboxEntry]) -> [String: MachineOutboxSummary] {
        Dictionary(grouping: entries.filter { $0.serverID == nil }, by: \.endpointID)
            .mapValues { pending in
                MachineOutboxSummary(
                    messageCount: pending.count { $0.kind == .sendMessage },
                    changeCount: pending.count { $0.kind != .sendMessage },
                    retrying: pending.contains { $0.state == .retrying },
                    failed: pending.contains { $0.state == .failed },
                    failureMessage: pending.reversed().first(where: { $0.state == .failed })?.lastError
                        ?? pending.reversed().first(where: { DieterRPCFailure.isInsufficientStorage($0.lastError) })?
                        .lastError
                )
            }
    }
}

enum MachineDeliveryToastPhase: Equatable, Sendable {
    case sending
    case waiting
    case waitingForStorage
    case retrying
    case failed
}

struct DieterFailedOutboxItem: Identifiable, Sendable {
    let id: String
    let operation: String
    let targetID: String
    let failure: String
    let createdAt: Date
}

struct ProjectFileNavigation: Equatable, Sendable {
    private static let historyLimit = 100
    private(set) var backwardPaths: [String] = []
    private(set) var forwardPaths: [String] = []

    var canGoBack: Bool { !backwardPaths.isEmpty }
    var canGoForward: Bool { !forwardPaths.isEmpty }

    static func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    mutating func recordNavigation(from currentPath: String, to destinationPath: String) {
        guard currentPath != destinationPath else { return }
        Self.append(currentPath, to: &backwardPaths)
        forwardPaths.removeAll(keepingCapacity: true)
    }

    mutating func goBack(from currentPath: String) -> String? {
        guard let destination = backwardPaths.popLast() else { return nil }
        Self.append(currentPath, to: &forwardPaths)
        return destination
    }

    mutating func goForward(from currentPath: String) -> String? {
        guard let destination = forwardPaths.popLast() else { return nil }
        Self.append(currentPath, to: &backwardPaths)
        return destination
    }

    mutating func reset() {
        backwardPaths.removeAll(keepingCapacity: true)
        forwardPaths.removeAll(keepingCapacity: true)
    }

    private static func append(_ path: String, to history: inout [String]) {
        history.append(path)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }
}

enum MachineRoutingPolicy {
    static func preferredDaemonID(newEndpoint: DieterEndpoint?, currentEndpoint: DieterEndpoint)
        -> String?
    {
        newEndpoint?.daemonID ?? (newEndpoint == nil ? currentEndpoint.daemonID : nil)
    }

    static func automaticConnectionTarget(
        from machines: [DieterEndpoint],
        preferredDaemonID: String?
    ) -> DieterEndpoint? {
        connectionTargets(
            from: machines,
            preferredDaemonID: preferredDaemonID,
            explicitMachineSelection: false
        ).first
    }

    static func connectionTargets(
        from machines: [DieterEndpoint],
        preferredDaemonID: String?,
        explicitMachineSelection: Bool
    ) -> [DieterEndpoint] {
        let online = machines.filter(\.online)
        if explicitMachineSelection, let preferredDaemonID {
            return online.filter { $0.daemonID == preferredDaemonID }
        }
        let eligible = online.filter { $0.compatibilityState != .incompatible }
        let sorted = eligible.sorted {
            let names = $0.name.localizedCaseInsensitiveCompare($1.name)
            if names != .orderedSame { return names == .orderedAscending }
            return $0.id < $1.id
        }
        guard let preferredIndex = sorted.firstIndex(where: { $0.daemonID == preferredDaemonID }) else {
            return sorted
        }
        var result = sorted
        let preferred = result.remove(at: preferredIndex)
        result.insert(preferred, at: 0)
        return result
    }
}

enum DieterAttachmentError: LocalizedError {
    case tooMany
    case fileTooLarge(String)
    case totalTooLarge
    case empty(String)
    case notAFile(String)
    case unsupportedPaste
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .tooMany: "You can attach up to 4 images or files."
        case .fileTooLarge(let name): "\(name) must be at most 5 MB."
        case .totalTooLarge: "Attachments must total at most 6 MB."
        case .empty(let name): "\(name) is empty."
        case .notAFile(let name): "\(name) is not a regular file."
        case .unsupportedPaste:
            "The clipboard does not contain an image or file that Dieter can attach."
        case .invalidImage: "The pasted image could not be decoded."
        }
    }
}
