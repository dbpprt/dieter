import DieterCore
import Darwin
import Foundation

/// Synced folders in the app's Documents container, which Files shows as On My iPhone › Dieter ›
/// Name (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`). A location is the folder's
/// directory name in Documents, so it survives the container moving on updates. Paths never pass
/// through a symlink; replacements and deletions run under `NSFileCoordinator`, so Files and other
/// apps see coordinated writes, and each first checks the state the core last observed. Every rule
/// stays in the core; Swift cannot throw into Kotlin, so outcomes are status codes.
public final class ContainerFolderFileSystem: NSObject, NativeFolderFileSystem, @unchecked Sendable {
    private let documents: URL
    /// "On My iPhone" or "On My iPad", as Files names the device.
    private let deviceLabel: String
    private let files = FileManager.default

    public init(documents: URL, deviceLabel: String) {
        self.documents = documents
        self.deviceLabel = deviceLabel
    }

    private enum Failure: Error {
        /// The item is not in the expected state; nothing was changed.
        case changed(String)
        case unavailable(String)
        case failed(String)
    }

    // MARK: Locations

    public func defaultLocation(folderId: String, name: String) -> NativeFolderLocation {
        let base = Self.directoryName(name)
        // A directory a removed folder left behind is never adopted silently: the next free name.
        var chosen = base
        for attempt in 2...100 where lstatInfo(documents.appendingPathComponent(chosen)) != nil {
            chosen = "\(base) \(attempt)"
        }
        if lstatInfo(documents.appendingPathComponent(chosen)) != nil { chosen = "\(base) \(folderId.prefix(8))" }
        return NativeFolderLocation(location: chosen, label: "\(deviceLabel) › Dieter › \(chosen)")
    }

    /// A name Files can show and the file system can store: no separators, no leading dot.
    static func directoryName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Folder" : cleaned
    }

    /// The location's directory; unusable locations are unavailable.
    private func rootURL(_ location: String) throws -> URL {
        guard !location.isEmpty, !location.contains("/"), !location.contains("\0"), !location.hasPrefix(".")
        else { throw Failure.unavailable("That is not a folder location on this device.") }
        return documents.appendingPathComponent(location, isDirectory: true)
    }

    /// The existing root directory, never a symlink.
    private func existingRoot(_ location: String) throws -> URL {
        let root = try rootURL(location)
        guard let info = lstatInfo(root), info.kind == Kind.directory else {
            throw Failure.unavailable("The folder location is unavailable.")
        }
        return root
    }

    /// `path` below the root, refusing odd components and symlinks on the way.
    private func resolve(_ location: String, _ path: String) throws -> URL {
        var url = try existingRoot(location)
        if path.isEmpty { return url }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part != ".", part != "..", !part.contains("\0") else {
                throw Failure.failed("\(path) is not a valid path.")
            }
            url.appendPathComponent(String(part))
            if index < parts.count - 1, let info = lstatInfo(url), info.kind == Kind.symlink {
                throw Failure.changed("\(path) passes through a symlink.")
            }
        }
        return url
    }

    public func prepare(location: String) -> String? {
        guard let root = try? rootURL(location) else { return nil }
        if lstatInfo(root) == nil {
            do {
                try files.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return rootIdentity(location: location)
    }

    /// The root's volume and inode: a replaced or recreated directory reads as another root.
    public func rootIdentity(location: String) -> String? {
        guard let root = try? rootURL(location), let info = lstatInfo(root), info.kind == Kind.directory else {
            return nil
        }
        let volume =
            (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? "dev\(info.device)"
        return "ios:\(volume):\(info.inode)"
    }

    // MARK: Reading

    public func list(location: String, directory: String) -> [NativeFolderFileInfo]? {
        guard (try? existingRoot(location)) != nil else { return nil }
        // A directory that vanished or turned into something else lists as empty; only a missing
        // root makes the folder unavailable.
        guard let folder = try? resolve(location, directory), let info = lstatInfo(folder),
            info.kind == Kind.directory,
            let names = try? files.contentsOfDirectory(atPath: folder.path)
        else { return [] }
        return names.compactMap { name in lstatInfo(folder.appendingPathComponent(name))?.native(name: name) }
    }

    public func stat(location: String, path: String) -> NativeFolderFileInfo? {
        guard let url = try? resolve(location, path) else { return nil }
        return lstatInfo(url)?.native(name: url.lastPathComponent)
    }

    public func read(location: String, path: String, offset: Int64, length: Int32) -> Data? {
        guard let url = try? resolve(location, path), let info = lstatInfo(url), info.kind == Kind.file,
            offset >= 0, length >= 0
        else { return nil }
        if offset >= info.size { return Data() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: Int(length)) ?? Data()
        } catch {
            return nil
        }
    }

    // MARK: Staging

    public func stagingSize(location: String, staging: String) -> Int64 {
        guard let url = try? resolve(location, staging), let info = lstatInfo(url), info.kind == Kind.file else {
            return -1
        }
        return info.size
    }

    public func writeStaging(location: String, staging: String, offset: Int64, data: Data) -> NativeFolderOutcome {
        outcome {
            let url = try resolve(location, staging)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = lstatInfo(url)
            if let existing, existing.kind != Kind.file {
                throw Failure.changed("The partial file is not a regular file.")
            }
            if existing == nil {
                guard offset == 0 else { throw Failure.changed("The partial file is gone.") }
                guard files.createFile(atPath: url.path, contents: nil) else {
                    throw Failure.failed("The partial file could not be created.")
                }
            } else if existing!.size < offset {
                throw Failure.changed("The partial file is shorter than expected.")
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seek(toOffset: UInt64(offset))
            if !data.isEmpty { try handle.write(contentsOf: data) }
            return nil
        }
    }

    public func discardStaging(location: String, staging: String) {
        guard let url = try? resolve(location, staging), let info = lstatInfo(url), info.kind == Kind.file else {
            return
        }
        try? files.removeItem(at: url)
    }

    // MARK: Changes

    public func publish(
        location: String, staging: String, path: String, expected: NativeFolderFileInfo?, modifiedNanos: Int64,
        executable: Bool
    ) -> NativeFolderOutcome {
        outcome {
            let source = try resolve(location, staging)
            let target = try resolve(location, path)
            guard let partial = lstatInfo(source), partial.kind == Kind.file else {
                throw Failure.changed("The download's partial file is gone.")
            }
            guard matches(target, expected) else { throw Failure.changed("The file changed on this device.") }
            try setModified(source, nanos: modifiedNanos)
            guard chmod(source.path, executable ? 0o755 : 0o644) == 0 else {
                throw Failure.failed(Self.errnoMessage("The file's permissions could not be set"))
            }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coordinate(writing: target, options: .forReplacing) { actual in
                // Checked again inside the coordinated write, where no other coordinated writer runs.
                guard matches(actual, expected) else { throw Failure.changed("The file changed on this device.") }
                if expected == nil {
                    // Create-only: an item that appeared meanwhile is never overwritten.
                    try renameExclusive(source, actual)
                } else {
                    _ = try files.replaceItemAt(
                        actual, withItemAt: source, backupItemName: nil, options: [.usingNewMetadataOnly])
                }
            }
            guard let published = lstatInfo(target) else { throw Failure.changed("The published file is gone.") }
            return published.native(name: target.lastPathComponent)
        }
    }

    public func delete(location: String, path: String, expected: NativeFolderFileInfo) -> NativeFolderOutcome {
        outcome {
            let url = try resolve(location, path)
            guard matches(url, expected) else { throw Failure.changed("The file changed on this device.") }
            try coordinate(writing: url, options: .forDeleting) { actual in
                guard matches(actual, expected) else { throw Failure.changed("The file changed on this device.") }
                let removed = actual.withUnsafeFileSystemRepresentation { pointer -> Int32 in
                    guard let pointer else { return -1 }
                    return expected.kind == Kind.directory ? rmdir(pointer) : unlink(pointer)
                }
                if removed != 0 && errno != ENOENT {
                    throw Failure.failed(Self.errnoMessage("\(path) could not be deleted"))
                }
            }
            return nil
        }
    }

    public func mkdir(location: String, path: String) -> NativeFolderOutcome {
        outcome {
            let url = try resolve(location, path)
            if let info = lstatInfo(url) {
                guard info.kind == Kind.directory else { throw Failure.changed("\(path) is not a directory.") }
                return nil
            }
            try files.createDirectory(at: url, withIntermediateDirectories: true)
            return nil
        }
    }

    public func removeDirectory(location: String, path: String) -> NativeFolderOutcome {
        outcome {
            let url = try resolve(location, path)
            guard let info = lstatInfo(url), info.kind == Kind.directory else { return nil }
            let children = try files.contentsOfDirectory(atPath: url.path)
            if !children.isEmpty { throw Failure.changed("\(path) is not empty.") }
            try coordinate(writing: url, options: .forDeleting) { actual in
                let removed = actual.withUnsafeFileSystemRepresentation { pointer -> Int32 in
                    guard let pointer else { return -1 }
                    return rmdir(pointer)
                }
                if removed != 0 {
                    if errno == ENOTEMPTY || errno == EEXIST { throw Failure.changed("\(path) is not empty.") }
                    if errno != ENOENT { throw Failure.failed(Self.errnoMessage("\(path) could not be removed")) }
                }
            }
            return nil
        }
    }

    public func move(location: String, from: String, to: String, expected: NativeFolderFileInfo)
        -> NativeFolderOutcome
    {
        outcome {
            let source = try resolve(location, from)
            let target = try resolve(location, to)
            guard matches(source, expected) else { throw Failure.changed("The file changed on this device.") }
            if lstatInfo(target) != nil { throw Failure.changed("\(to) already exists.") }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var coordinationError: NSError?
            var moveError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing,
                error: &coordinationError
            ) { actualSource, actualTarget in
                do {
                    guard matches(actualSource, expected) else {
                        throw Failure.changed("The file changed on this device.")
                    }
                    try renameExclusive(actualSource, actualTarget)
                } catch {
                    moveError = error
                }
            }
            if let coordinationError { throw Failure.failed(coordinationError.localizedDescription) }
            if let moveError { throw moveError }
            return nil
        }
    }

    public func freeBytes(location: String) -> Int64 {
        let root = (try? existingRoot(location)) ?? documents
        if let values = try? root.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]) {
            if let important = values.volumeAvailableCapacityForImportantUsage { return important }
            if let available = values.volumeAvailableCapacity { return Int64(available) }
        }
        // Unknown space reads as none, so downloads wait instead of filling the device.
        return 0
    }

    /// The platform owns the location, so the directory itself goes too.
    public func deleteAll(location: String) -> NativeFolderOutcome {
        outcome {
            let root = try rootURL(location)
            guard lstatInfo(root) != nil else { return nil }
            try coordinate(writing: root, options: .forDeleting) { actual in
                if lstatInfo(actual) != nil { try files.removeItem(at: actual) }
            }
            return nil
        }
    }

    // MARK: Support

    private func outcome(_ body: () throws -> NativeFolderFileInfo?) -> NativeFolderOutcome {
        do {
            return NativeFolderOutcome(status: 0, message: nil, info: try body())
        } catch Failure.changed(let message) {
            return NativeFolderOutcome(status: 1, message: message, info: nil)
        } catch Failure.unavailable(let message) {
            return NativeFolderOutcome(status: 2, message: message, info: nil)
        } catch Failure.failed(let message) {
            return NativeFolderOutcome(status: 3, message: message, info: nil)
        } catch {
            return NativeFolderOutcome(status: 3, message: error.localizedDescription, info: nil)
        }
    }

    private func coordinate(
        writing url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: options, error: &coordinationError
        ) { actual in
            do { try body(actual) } catch { bodyError = error }
        }
        if let coordinationError { throw Failure.failed(coordinationError.localizedDescription) }
        if let bodyError { throw bodyError }
    }

    /// Renames `source` to `target` only when nothing is at `target`.
    private func renameExclusive(_ source: URL, _ target: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { from in
            target.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return -1 }
                return renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        if result == 0 { return }
        if errno == EEXIST { throw Failure.changed("Something appeared at \(target.lastPathComponent).") }
        throw Failure.failed(Self.errnoMessage("\(target.lastPathComponent) could not be written"))
    }

    private func setModified(_ url: URL, nanos: Int64) throws {
        let seconds = nanos / 1_000_000_000
        let remainder = nanos % 1_000_000_000
        let time = timespec(tv_sec: Int(seconds), tv_nsec: Int(remainder))
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), time]
        let result = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return utimensat(AT_FDCWD, pointer, &times, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 { throw Failure.failed(Self.errnoMessage("The file's modification time could not be set")) }
    }

    /// Whether `url` is in the state the core observed: nothing there (nil), or the same kind,
    /// size, modification time and token.
    private func matches(_ url: URL, _ expected: NativeFolderFileInfo?) -> Bool {
        let now = lstatInfo(url)
        guard let expected else { return now == nil }
        guard let now else { return false }
        return now.kind == expected.kind && now.size == expected.size && now.modifiedNanos == expected.modifiedNanos
            && now.token == expected.token
    }

    private static func errnoMessage(_ what: String) -> String {
        "\(what): \(String(cString: strerror(errno)))."
    }

    enum Kind {
        static let file: Int32 = 0
        static let directory: Int32 = 1
        static let symlink: Int32 = 2
        static let other: Int32 = 3
    }

    struct Info {
        let kind: Int32
        let size: Int64
        let modifiedNanos: Int64
        let inode: UInt64
        let device: Int32
        let executable: Bool

        /// Changes whenever the item is replaced (a new inode) or rewritten (its modification time
        /// or size); extended attributes Files adds while previewing do not count as changes.
        var token: String { "\(inode):\(modifiedNanos):\(size)" }

        func native(name: String) -> NativeFolderFileInfo {
            NativeFolderFileInfo(
                name: name, kind: kind, size: size, modifiedNanos: modifiedNanos, token: token,
                executable: executable)
        }
    }

    /// The item at `url` without following a symlink; nil when nothing is there.
    func lstatInfo(_ url: URL) -> Info? {
        var status = Darwin.stat()
        let result = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return lstat(pointer, &status)
        }
        guard result == 0 else { return nil }
        let kind: Int32
        switch status.st_mode & S_IFMT {
        case S_IFREG: kind = Kind.file
        case S_IFDIR: kind = Kind.directory
        case S_IFLNK: kind = Kind.symlink
        default: kind = Kind.other
        }
        let modified = Int64(status.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(status.st_mtimespec.tv_nsec)
        return Info(
            kind: kind, size: kind == Kind.file ? Int64(status.st_size) : 0, modifiedNanos: modified,
            inode: UInt64(status.st_ino), device: Int32(status.st_dev),
            executable: kind == Kind.file && status.st_mode & S_IXUSR != 0)
    }
}
