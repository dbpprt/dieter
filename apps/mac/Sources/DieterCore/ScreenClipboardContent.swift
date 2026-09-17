import Foundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import Darwin

// Shared by the viewer and the standalone capture helper. Never put source
// paths on the wire: regular file bytes are copied into a private staging root.
public struct ScreenClipboardItem: Codable, Sendable, Equatable {
    public var kind: Int32
    public var name: String
    public var mimeType: String
    public var data: Data
    public init(kind: Int32, name: String, mimeType: String, data: Data) {
        self.kind = kind; self.name = name; self.mimeType = mimeType; self.data = data
    }
}
public struct ScreenClipboardContent: Sendable {
    public static let binaryLimit = 8 * 1024 * 1024
    public var text: String?
    public var items: [ScreenClipboardItem]
    public init(text: String? = nil, items: [ScreenClipboardItem] = []) { self.text = text; self.items = items }
    public static func error(_ message: String) -> NSError {
        NSError(domain: "DieterClipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    public func validate() throws {
        guard (text?.utf8.count ?? 0) <= 1024 * 1024, items.count <= 64,
            items.reduce(0, { $0 + $1.data.count }) <= Self.binaryLimit,
            text == nil || items.isEmpty else { throw Self.error("Clipboard limit: 1 MiB text or 8 MiB across 64 files") }
        var names = Set<String>()
        for item in items {
            guard !item.name.isEmpty, item.name.utf8.count <= 255, ![".", ".."].contains(item.name),
                !item.name.contains("/"), !item.name.contains("\\"), !item.name.contains("\0"),
                names.insert(item.name.precomposedStringWithCanonicalMapping.lowercased()).inserted, item.mimeType.utf8.count <= 128,
                item.kind == 0 || (item.kind == 1 && items.count == 1 && ["image/png", "image/jpeg", "image/tiff", "image/webp"].contains(item.mimeType))
            else { throw Self.error("Invalid clipboard file or image") }
        }
    }
    public static func read(_ board: NSPasteboard, binary: Bool) throws -> Self {
        // File URLs often also expose a text representation. Do not sync the
        // source machine's paths as text when a peer lacks binary support.
        if board.availableType(from: [.fileURL]) != nil {
            guard binary else { return Self() }
            let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty, urls.count <= 64 else { throw error("Clipboard contains too many files") }
            var items: [ScreenClipboardItem] = []; var total = 0
            for url in urls {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw error("Copy regular files; folders and symbolic links are not supported") }
                guard let size = values.fileSize, size <= binaryLimit - total else { throw error("Clipboard files exceed 8 MiB") }
                let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard descriptor >= 0 else { throw error("Clipboard file cannot be opened") }
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                    Darwin.close(descriptor); throw error("Clipboard requires regular files")
                }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                var data = Data()
                do {
                    while let part = try handle.read(upToCount: min(65536, binaryLimit - total - data.count + 1)), !part.isEmpty {
                        data.append(part)
                        guard data.count + total <= binaryLimit else { throw error("Clipboard files exceed 8 MiB") }
                    }
                    try handle.close()
                } catch { try? handle.close(); throw error }
                total += data.count
                guard total <= binaryLimit else { throw error("Clipboard files exceed 8 MiB") }
                items.append(.init(kind: 0, name: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: data))
            }
            let value = Self(items: items); try value.validate(); return value
        }
        if let type = board.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("org.webmproject.webp")]) {
            guard binary else { return Self() }
            guard let data = board.data(forType: type), data.count <= binaryLimit else { throw error("Clipboard image is unavailable or exceeds 8 MiB") }
            let format = UTType(type.rawValue)
            let value = Self(items: [.init(kind: 1, name: "Clipboard.\(format?.preferredFilenameExtension ?? "png")", mimeType: format?.preferredMIMEType ?? "image/png", data: data)])
            try value.validate(); return value
        }
        let value = Self(text: board.string(forType: .string)); try value.validate(); return value
    }
    public func write(_ board: NSPasteboard, directory: URL) throws {
        try validate()
        if let text {
            board.clearContents()
            guard board.setString(text, forType: .string) else { throw Self.error("Clipboard write failed") }
        } else if let image = items.first, image.kind == 1 {
            guard let type = UTType(mimeType: image.mimeType) else { throw Self.error("Unsupported clipboard image") }
            board.clearContents()
            guard board.setData(image.data, forType: .init(type.identifier)) else { throw Self.error("Clipboard image write failed") }
        } else if !items.isEmpty {
            let urls = try stage(directory: directory)
            board.clearContents()
            guard board.writeObjects(urls as [NSURL]) else { throw Self.error("Clipboard file write failed") }
        }
    }
    public static var defaultDirectory: URL {
        let home = ProcessInfo.processInfo.environment["DIETER_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dieter", isDirectory: true)
        return home.appendingPathComponent("clipboard", isDirectory: true)
    }
    private func stage(directory: URL) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw Self.error("Clipboard staging lock unavailable") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw Self.error("Clipboard staging lock failed") }
        defer { flock(lock, LOCK_UN) }
        // Keep at most eight recent batches (64 MiB); stale URLs expire after
        // 24 hours. Never remove arbitrary user paths or follow directory links.
        let existing = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasPrefix("transfer-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for (index, url) in existing.enumerated() {
            let info = try url.resourceValues(forKeys: [.creationDateKey, .isSymbolicLinkKey])
            if info.isSymbolicLink != true && (index < existing.count - 7 || (info.creationDate ?? .distantPast).timeIntervalSinceNow < -86400) {
                try fm.removeItem(at: url)
            }
        }
        let batch = directory.appendingPathComponent("transfer-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: batch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            return try items.map { item in
                let url = batch.appendingPathComponent(item.name)
                try item.data.write(to: url, options: [.atomic])
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return url
            }
        } catch { try? fm.removeItem(at: batch); throw error }
    }
}
#endif
