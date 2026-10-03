import FamilyCore
import SwiftUI

struct NotesHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let membership = app.currentMembership, membership.role.isAtLeast(.adult) {
            NotesListView(model: NotesModel(family: membership.family, service: app.services.notes))
                .id(membership.id)
        } else {
            ContentUnavailableView("notes.noAccess", systemImage: "lock")
        }
    }
}

private struct NotesListView: View {
    @State var model: NotesModel
    @State private var editing: NoteDraft?

    var body: some View {
        List {
            if model.visible.isEmpty && !model.isLoading {
                ContentUnavailableView(model.query.isEmpty ? "notes.empty" : "notes.noResults", systemImage: "note.text")
            }
            ForEach(model.visible) { note in
                Button { editing = NoteDraft(note: note) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if note.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                            if note.isPrivate { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
                            Text(NoteOrdering.displayTitle(title: note.title, body: note.body)).font(.headline).lineLimit(1)
                        }
                        Text(note.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .foregroundStyle(.primary)
                }
                .swipeActions(edge: .leading) {
                    Button { Task { await model.togglePin(note) } } label: { Label("notes.pin", systemImage: "pin") }
                        .tint(.orange)
                }
            }
            .onDelete { offsets in
                let items = offsets.map { model.visible[$0] }
                Task { for item in items { await model.delete(item) } }
            }
        }
        .navigationTitle("notes.title")
        .searchable(text: $model.query)
        .toolbar {
            Button { editing = NoteDraft(note: nil) } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel(Text("notes.add"))
                .accessibilityIdentifier("addNoteButton")
        }
        .sheet(item: $editing) { draft in NoteEditorView(model: model, draft: draft) }
        .refreshable { await model.load() }
        .task { await model.load() }
        .alert("error.title", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(model.error?.localizedDescription ?? "")
        }
    }
}

struct NoteDraft: Identifiable {
    let note: Note?
    var id: UUID { note?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
}

private struct NoteEditorView: View {
    let model: NotesModel
    let draft: NoteDraft
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String
    @State private var isPrivate: Bool
    @State private var action = AsyncAction()

    init(model: NotesModel, draft: NoteDraft) {
        self.model = model
        self.draft = draft
        _title = State(initialValue: draft.note?.title ?? "")
        _text = State(initialValue: draft.note?.body ?? "")
        _isPrivate = State(initialValue: draft.note?.isPrivate ?? false)
    }

    private var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("notes.titleField", text: $title).accessibilityIdentifier("noteTitleField")
                TextField("notes.body", text: $text, axis: .vertical).lineLimit(6...20)
                // Privacy is fixed when the note is created.
                if draft.note == nil {
                    Toggle("notes.private", isOn: $isPrivate)
                } else if isPrivate {
                    Label("notes.private", systemImage: "eye.slash").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(draft.note == nil ? "notes.add" : "notes.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        Task {
                            await action.run {
                                if var note = draft.note {
                                    note.title = title
                                    note.body = text
                                    try await model.save(note)
                                } else {
                                    try await model.add(title: title, body: text, isPrivate: isPrivate)
                                }
                                dismiss()
                            }
                        }
                    }
                    .disabled(isEmpty || action.isRunning)
                    .accessibilityIdentifier("saveNoteButton")
                }
            }
            .errorAlert(action)
        }
    }
}
