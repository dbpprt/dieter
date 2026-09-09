import Foundation

/// Rebuildable in-memory index of synchronized task metadata, never transcripts.
public struct TaskSearchIndex {
    public struct Document: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let text: String
        public let location: String
        public let updatedAt: String
        public let archived: Bool
        public let isChat: Bool

        public init(
            id: String, title: String, text: String, location: String, updatedAt: String,
            archived: Bool = false, isChat: Bool = false
        ) {
            self.id = id; self.title = title; self.text = text; self.location = location
            self.updatedAt = updatedAt; self.archived = archived; self.isChat = isChat
        }
    }

    private var documents: [String: Document] = [:]
    private var postings: [String: Set<String>] = [:]

    public init(documents: [Document] = []) {
        for document in documents {
            if let existing = self.documents[document.id], existing.updatedAt > document.updatedAt { continue }
            self.documents[document.id] = document
        }
        for document in self.documents.values where !document.archived {
            for word in Set(
                Self.words(document.title + " " + document.text + " " + document.location + " " + document.id))
            {
                postings[word, default: []].insert(document.id)
            }
        }
    }

    public func search(_ query: String, limit: Int = 30) -> [Document] {
        let terms = Self.words(query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        var candidates: Set<String>?
        for term in terms {
            let matches = postings.filter { $0.key.hasPrefix(term) }.values.reduce(into: Set<String>()) {
                $0.formUnion($1)
            }
            candidates = candidates.map { $0.intersection(matches) } ?? matches
            if candidates?.isEmpty == true { return [] }
        }
        let phrase = Self.normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        func score(_ document: Document) -> Int {
            let title = Self.normalize(document.title)
            if title == phrase { return 3 }
            if title.hasPrefix(phrase) { return 2 }
            return terms.allSatisfy { term in Self.words(title).contains { $0.hasPrefix(term) } } ? 1 : 0
        }
        return Array(
            (candidates ?? []).compactMap { documents[$0] }.sorted {
                let lhs = score($0), rhs = score($1)
                if lhs != rhs { return lhs > rhs }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }.prefix(limit))
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func words(_ value: String) -> [String] {
        normalize(value).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
