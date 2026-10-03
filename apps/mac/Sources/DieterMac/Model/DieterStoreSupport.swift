import AppKit
import DieterAPI
import Foundation
import Observation
import UniformTypeIdentifiers
import UserNotifications

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
