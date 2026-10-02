import FamilyCore
import SwiftUI

/// Shown after MFA when the user belongs to no family: create one or accept an invitation.
struct NoFamilyView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var currency = CurrencyCode.eur
    @State private var invitations: [Invitation] = []
    @State private var action = AsyncAction()

    var body: some View {
        NavigationStack {
            Form {
                if !invitations.isEmpty {
                    Section("family.invitations") {
                        ForEach(invitations) { invitation in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("family.invitation.role \(Text(invitation.role.titleKey))")
                                HStack {
                                    Button("family.invitation.accept") {
                                        Task {
                                            await action.run {
                                                try await model.services.family.accept(invitation)
                                                try await model.loadMemberships()
                                            }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    Button("family.invitation.decline", role: .destructive) {
                                        Task {
                                            await action.run {
                                                try await model.services.family.decline(invitation)
                                                invitations.removeAll { $0.id == invitation.id }
                                            }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                Section {
                    TextField("family.name", text: $name)
                        .accessibilityIdentifier("familyNameField")
                    Picker("family.currency", selection: $currency) {
                        ForEach(CurrencyCode.common, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Button("family.create") {
                        Task {
                            await action.run {
                                let id = try await model.services.family.createFamily(
                                    name: name.trimmingCharacters(in: .whitespaces), currency: currency)
                                model.selectedFamilyId = id
                                try await model.loadMemberships()
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || action.isRunning)
                    .accessibilityIdentifier("createFamilyButton")
                } header: {
                    Text("family.create.header")
                } footer: {
                    Text("family.create.footer")
                }
                Section {
                    Button("settings.signOut", role: .destructive) { Task { await model.signOut() } }
                }
            }
            .navigationTitle("family.welcome")
            .errorAlert(action)
            .refreshable { await loadInvitations() }
            .task { await loadInvitations() }
        }
    }

    private func loadInvitations() async {
        invitations = (try? await model.services.family.myInvitations()) ?? []
    }
}

struct FamilyView: View {
    @Environment(AppModel.self) private var model
    @State private var members: [MemberProfile] = []
    @State private var approvals: [ApprovalRequest] = []
    @State private var showInvite = false
    @State private var action = AsyncAction()
    @State private var notice: LocalizedStringKey?

    private var membership: Membership? { model.currentMembership }
    private var isAdmin: Bool { membership?.role == .admin }

    var body: some View {
        NavigationStack {
            List {
                if model.memberships.count > 1 {
                    Section {
                        Picker("family.current", selection: Binding(
                            get: { model.selectedFamilyId ?? membership?.family.id },
                            set: { model.selectedFamilyId = $0 })) {
                            ForEach(model.memberships) { Text($0.family.name).tag(Optional($0.family.id)) }
                        }
                    }
                }
                if isAdmin && !approvals.isEmpty {
                    Section {
                        ForEach(approvals) { request in
                            ApprovalRow(request: request, members: members, currentUserId: model.userId) { approve in
                                Task {
                                    await action.run {
                                        if approve {
                                            try await model.services.family.approve(request)
                                        } else {
                                            try await model.services.family.reject(request)
                                        }
                                        await load()
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("approvals.header")
                    } footer: {
                        Text("approvals.footer")
                    }
                }
                Section("family.members") {
                    ForEach(members) { member in
                        HStack {
                            Text(member.displayName.isEmpty ? String(localized: "family.member.unnamed") : member.displayName)
                            Spacer()
                            Text(member.role.titleKey).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            if isAdmin && member.userId != model.userId {
                                Button("family.member.remove", role: .destructive) {
                                    request { try await model.services.family.requestRemoval(
                                        familyId: $0, userId: member.userId) }
                                }
                            }
                        }
                        .contextMenu {
                            if isAdmin {
                                ForEach(MemberRole.allCases.filter { $0 != member.role }, id: \.self) { role in
                                    Button {
                                        request { try await model.services.family.requestRoleChange(
                                            familyId: $0, userId: member.userId, role: role) }
                                    } label: {
                                        Text("family.member.makeRole \(Text(role.titleKey))")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(membership?.family.name ?? "")
            .toolbar {
                if isAdmin {
                    Button { showInvite = true } label: { Image(systemName: "person.badge.plus") }
                        .accessibilityLabel(Text("family.invite"))
                }
            }
            .sheet(isPresented: $showInvite) {
                InviteMemberView { outcome in
                    notice = outcome == .executed ? LocalizedStringKey("family.invite.sent") : LocalizedStringKey("approvals.waiting")
                    Task { await load() }
                }
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("common.ok", role: .cancel) {}
            }
            .errorAlert(action)
            .refreshable { await load() }
            .task(id: model.selectedFamilyId) { await load() }
        }
    }

    private func request(_ operation: @escaping (UUID) async throws -> ActionRequestOutcome) {
        guard let familyId = membership?.family.id else { return }
        Task {
            await action.run {
                let outcome = try await operation(familyId)
                notice = outcome == .executed ? LocalizedStringKey("approvals.done") : LocalizedStringKey("approvals.waiting")
                await load()
            }
        }
    }

    private func load() async {
        guard let familyId = membership?.family.id else { return }
        await action.run {
            members = try await model.services.family.members(of: familyId)
            approvals = isAdmin ? try await model.services.family.pendingApprovals(familyId: familyId) : []
        }
    }
}

private struct ApprovalRow: View {
    let request: ApprovalRequest
    let members: [MemberProfile]
    let currentUserId: UUID?
    let decide: (Bool) -> Void

    private func name(_ id: String?) -> String {
        guard let id, let uuid = UUID(uuidString: id) else { return "" }
        return members.first { $0.userId == uuid }?.displayName ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch request.action {
            case .inviteMember:
                Text("approvals.invite \(request.payload["email"] ?? "")")
            case .removeMember:
                Text("approvals.remove \(name(request.payload["user_id"]))")
            case .changeRole:
                Text("approvals.changeRole \(name(request.payload["user_id"]))")
            case .deleteFamily:
                Text("approvals.deleteFamily")
            }
            Text("approvals.by \(name(request.requestedBy?.uuidString))")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if request.requestedBy != currentUserId {
                HStack {
                    Button("approvals.approve") { decide(true) }.buttonStyle(.borderedProminent)
                    Button("approvals.reject", role: .destructive) { decide(false) }.buttonStyle(.bordered)
                }
            } else {
                Button("approvals.cancel", role: .destructive) { decide(false) }.buttonStyle(.bordered)
            }
        }
    }
}

struct InviteMemberView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role = MemberRole.adult
    @State private var action = AsyncAction()
    let onDone: (ActionRequestOutcome) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("auth.email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("family.role", selection: $role) {
                    ForEach(MemberRole.allCases, id: \.self) { Text($0.titleKey).tag($0) }
                }
                Section {
                    Text(role.descriptionKey).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("family.invite")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("family.invite.send") {
                        guard let familyId = model.currentMembership?.family.id else { return }
                        Task {
                            await action.run {
                                let outcome = try await model.services.family.invite(
                                    familyId: familyId, email: email.trimmingCharacters(in: .whitespaces), role: role)
                                dismiss()
                                onDone(outcome)
                            }
                        }
                    }
                    .disabled(!email.contains("@") || action.isRunning)
                }
            }
            .errorAlert(action)
        }
    }
}

extension MemberRole {
    var titleKey: LocalizedStringKey {
        switch self {
        case .admin: "role.admin"
        case .adult: "role.adult"
        case .child: "role.child"
        case .guest: "role.guest"
        }
    }

    var descriptionKey: LocalizedStringKey {
        switch self {
        case .admin: "role.admin.description"
        case .adult: "role.adult.description"
        case .child: "role.child.description"
        case .guest: "role.guest.description"
        }
    }
}

extension CurrencyCode {
    static let common: [CurrencyCode] = ["EUR", "USD", "GBP", "CHF", "RUB", "BRL"].compactMap(CurrencyCode.init)
}
