import FamilyCore
import Foundation
import Observation

@MainActor
@Observable
final class NotesModel {
    private(set) var notes: [Note] = []
    private(set) var isLoading = false
    var query = ""
    var error: AppError?

    let family: Family
    private let service: any NoteServicing

    init(family: Family, service: any NoteServicing) {
        self.family = family
        self.service = service
    }

    /// Pinned first, newest first, narrowed by the search query.
    var visible: [Note] {
        let order = NoteOrdering.filtered(notes.map(\.summary), query: query).map(\.id)
        let byId = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        return order.compactMap { byId[$0] }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await perform { notes = try await service.notes(familyId: family.id) }
    }

    func add(title: String, body: String, isPrivate: Bool) async throws {
        try await service.add(familyId: family.id, title: title, body: body, isPrivate: isPrivate)
        await load()
    }

    func save(_ note: Note) async throws {
        try await service.update(note)
        await load()
    }

    func togglePin(_ note: Note) async {
        var changed = note
        changed.pinned.toggle()
        await perform {
            try await service.update(changed)
            notes = try await service.notes(familyId: family.id)
        }
    }

    func delete(_ note: Note) async {
        await perform {
            try await service.delete(note)
            notes.removeAll { $0.id == note.id }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch let appError as AppError { error = appError } catch { self.error = .unknown }
    }
}
