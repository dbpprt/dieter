import AppKit
import DieterAPI
import Foundation
import OSLog
import Observation
import UniformTypeIdentifiers
import UserNotifications

/// How much terminal output the app keeps per terminal for replay.
let terminalClientBufferLimit = 2 * 1_024 * 1_024
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

struct DieterFailedOutboxItem: Identifiable, Sendable {
    let id: String
    let operation: String
    let targetID: String
    let failure: String
    let createdAt: Date
}

/// Folder history, as the shared core reports it for one files surface.
struct ProjectFileNavigation: Equatable, Sendable {
    var canGoBack = false
    var canGoForward = false
}

enum DieterAttachmentError: LocalizedError {
    /// The shared core's wording of a broken attachment limit.
    case limit(String)
    case notAFile(String)
    case unsupportedPaste
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .limit(let problem): problem
        case .notAFile(let name): "\(name) is not a regular file."
        case .unsupportedPaste:
            "The clipboard does not contain an image or file that Dieter can attach."
        case .invalidImage: "The pasted image could not be decoded."
        }
    }
}
