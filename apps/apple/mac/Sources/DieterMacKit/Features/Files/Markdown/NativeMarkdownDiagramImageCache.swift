import AppKit
import MarkdownEngine

/// Completed vectors for one reader's lifetime. No pages, tasks or failures
/// survive navigation, and nothing is persisted or shared between Mail models.
@MainActor
final class NativeMarkdownDiagramImageCache {
    private let maximumEntries: Int
    private let maximumBytes: Int
    private var entries: [NativeMarkdownDiagramKey: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var revision: UInt64 = 0
    private(set) var cachedBytes = 0
    private(set) var reuseCount = 0
    var cachedCount: Int { entries.count }

    private struct Entry {
        let result: RenderedCodeBlockResult
        let bytes: Int
        var used: UInt64
    }

    init(maximumEntries: Int = 48, maximumBytes: Int = 24 * 1024 * 1024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
    }

    func result(for key: NativeMarkdownDiagramKey) -> RenderedCodeBlockResult? {
        guard var entry = entries[key] else { return nil }
        reuseCount += 1
        clock &+= 1
        entry.used = clock
        entries[key] = entry
        return entry.result
    }

    func insert(_ result: RenderedCodeBlockResult, for key: NativeMarkdownDiagramKey) {
        // A document may supply a placeholder or a test bitmap. Only successful
        // vector output belongs in the reader's reusable cache.
        guard !result.image.representations.isEmpty,
            result.image.representations.allSatisfy({ $0 is NSPDFImageRep })
        else { return }
        let bytes = result.image.representations.reduce(key.sourceID.byteCount) {
            $0 + ($1 as! NSPDFImageRep).pdfRepresentation.count
        }
        guard bytes <= maximumBytes else { return }
        if let previous = entries.removeValue(forKey: key) { cachedBytes -= previous.bytes }
        while entries.count >= maximumEntries || cachedBytes + bytes > maximumBytes {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key,
                let removed = entries.removeValue(forKey: oldest)
            else { break }
            cachedBytes -= removed.bytes
        }
        clock &+= 1
        entries[key] = Entry(result: result, bytes: bytes, used: clock)
        cachedBytes += bytes
    }

    func removeAll() {
        revision &+= 1
        entries.removeAll()
        cachedBytes = 0
        reuseCount = 0
    }
}
