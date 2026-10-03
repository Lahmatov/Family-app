import FamilyCore
import SwiftUI

struct TasksHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let membership = app.currentMembership, membership.role.isAtLeast(.child) {
            TasksListView(model: TasksModel(family: membership.family, service: app.services.tasks,
                                            familyService: app.services.family, userId: app.userId, role: membership.role))
                .id(membership.id)
        } else {
            ContentUnavailableView("tasks.noAccess", systemImage: "lock")
        }
    }
}

private struct TasksListView: View {
    @State var model: TasksModel
    @State private var showAdd = false
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            if model.tasks.isEmpty && !model.isLoading {
                ContentUnavailableView("tasks.empty", systemImage: "checklist", description: Text("tasks.empty.description"))
            }
            ForEach(model.ordered) { task in
                HStack {
                    Button { Task { await model.setStatus(task, task.status == .done ? .todo : .done) } } label: {
                        Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(task.status == .done ? .green : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(task.status == .done ? "tasks.reopen" : "tasks.complete"))
                    NavigationLink(value: task.id) { TaskRow(task: task, model: model, locale: locale) }
                }
                .swipeActions {
                    if model.canDelete(task) {
                        Button("common.delete", role: .destructive) { Task { await model.delete(task) } }
                    }
                }
            }
        }
        .navigationTitle("tasks.title")
        .navigationDestination(for: UUID.self) { id in TaskDetailView(model: model, taskId: id) }
        .toolbar {
            Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
                .accessibilityLabel(Text("tasks.add"))
                .accessibilityIdentifier("addTaskButton")
        }
        .sheet(isPresented: $showAdd) { AddTaskView(model: model) }
        .refreshable { await model.load() }
        .task { await model.load() }
        .alert("error.title", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(model.error?.localizedDescription ?? "")
        }
    }
}

private struct TaskRow: View {
    let task: FamilyTask
    let model: TasksModel
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title).strikethrough(task.status == .done)
            HStack(spacing: 8) {
                if task.status == .doing { Label("tasks.status.doing", systemImage: "hourglass") }
                if let name = model.name(of: task.assigneeId) { Label(name, systemImage: "person") }
                if let due = task.dueOn {
                    Label(due.formatted(locale: locale), systemImage: "calendar")
                        .foregroundStyle(model.isOverdue(task) ? .red : .secondary)
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct TaskDetailView: View {
    let model: TasksModel
    let taskId: UUID
    @State private var newComment = ""
    @Environment(\.locale) private var locale

    var body: some View {
        if let task = model.tasks.first(where: { $0.id == taskId }) {
            List {
                Section {
                    Picker("tasks.status", selection: Binding(
                        get: { task.status }, set: { status in Task { await model.setStatus(task, status) } })) {
                        ForEach(TaskStatus.allCases, id: \.self) { Text(LocalizedStringKey("tasks.status." + $0.rawValue)).tag($0) }
                    }
                    Picker("tasks.assignee", selection: Binding(
                        get: { task.assigneeId }, set: { id in Task { await model.setAssignee(task, id) } })) {
                        Text("tasks.unassigned").tag(UUID?.none)
                        ForEach(model.members, id: \.userId) { Text($0.displayName).tag(Optional($0.userId)) }
                    }
                    if let due = task.dueOn {
                        LabeledContent("tasks.due", value: due.formatted(locale: locale))
                            .foregroundStyle(model.isOverdue(task) ? .red : .primary)
                    }
                    if let description = task.description, !description.isEmpty { Text(description) }
                }
                Section("tasks.discussion") {
                    ForEach(model.comments(for: task)) { comment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(comment.body)
                            Text("\(model.name(of: comment.createdBy) ?? "") · \(comment.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        TextField("tasks.comment", text: $newComment, axis: .vertical)
                            .accessibilityIdentifier("taskCommentField")
                        Button {
                            let body = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
                            newComment = ""
                            Task { await model.addComment(body, to: task) }
                        } label: { Image(systemName: "paperplane.fill") }
                            .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel(Text("tasks.send"))
                            .accessibilityIdentifier("sendTaskCommentButton")
                    }
                }
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("tasks.gone", systemImage: "questionmark.folder")
        }
    }
}

private struct AddTaskView: View {
    let model: TasksModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var assignee: UUID?
    @State private var hasDue = false
    @State private var due = Date()
    @State private var action = AsyncAction()

    var body: some View {
        NavigationStack {
            Form {
                TextField("tasks.name", text: $title).accessibilityIdentifier("taskTitleField")
                TextField("tasks.description", text: $details, axis: .vertical)
                Picker("tasks.assignee", selection: $assignee) {
                    Text("tasks.unassigned").tag(UUID?.none)
                    ForEach(model.members, id: \.userId) { Text($0.displayName).tag(Optional($0.userId)) }
                }
                Toggle("tasks.hasDue", isOn: $hasDue)
                if hasDue { DatePicker("tasks.due", selection: $due, displayedComponents: .date) }
            }
            .navigationTitle("tasks.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || action.isRunning)
                        .accessibilityIdentifier("saveTaskButton")
                }
            }
            .errorAlert(action)
        }
    }

    private func save() {
        let text = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = NewFamilyTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                 description: text.isEmpty ? nil : text, assigneeId: assignee, dueOn: hasDue ? LocalDate(due) : nil)
        Task { await action.run { try await model.add(task); dismiss() } }
    }
}
