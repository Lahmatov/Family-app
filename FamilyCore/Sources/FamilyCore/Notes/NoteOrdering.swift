import Foundation

/// The parts of a note that ordering and search need.
public struct NoteSummary: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let body: String
    public let pinned: Bool
    public let updatedAt: Date

    public init(id: UUID, title: String, body: String, pinned: Bool, updatedAt: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.pinned = pinned
        self.updatedAt = updatedAt
    }
}

public enum NoteOrdering {
    /// Pinned first, then most recently edited; ties break by id so the order is stable.
    public static func sorted(_ notes: [NoteSummary]) -> [NoteSummary] {
        notes.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Case- and accent-insensitive: "cafe" finds "Café", "acucar" finds "açúcar".
    /// Every word of the query must appear in the title or the body.
    public static func matches(_ note: NoteSummary, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = note.title + "\n" + note.body
        return words.allSatisfy {
            haystack.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    public static func filtered(_ notes: [NoteSummary], query: String) -> [NoteSummary] {
        sorted(notes).filter { matches($0, query: query) }
    }

    /// First non-empty line of the title, or of the body when the title is empty.
    public static func displayTitle(title: String, body: String) -> String {
        let source = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? body : title
        return source.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}
