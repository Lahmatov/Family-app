import FamilyCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Entry point: adults only, and every visit asks for Face ID / passcode again before keys are unwrapped.
struct VaultHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let membership = app.currentMembership, membership.role.isAtLeast(.adult), let userId = app.userId {
            VaultGateView(userId: userId, membership: membership, services: app.services)
                .id(membership.id)
        } else {
            ContentUnavailableView("vault.noAccess", systemImage: "lock")
        }
    }
}

private struct VaultGateView: View {
    @State private var model: VaultModel
    @State private var unlocked = false
    @State private var denied = false
    private let authenticator: any DeviceAuthenticating

    init(userId: UUID, membership: Membership, services: Services) {
        let familyId = membership.family.id
        let family = services.family
        _model = State(initialValue: VaultModel(
            userId: userId, familyId: familyId, role: membership.role, service: services.vault,
            identities: services.vaultIdentities, members: { try await family.members(of: familyId) }))
        authenticator = makeDeviceAuthenticator()
    }

    var body: some View {
        Group {
            if !unlocked {
                VStack(spacing: 16) {
                    ContentUnavailableView("vault.locked", systemImage: "lock.doc",
                                           description: Text(denied ? "vault.locked.denied" : "vault.locked.description"))
                    Button("vault.unlock") { Task { await unlock() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("vaultUnlockButton")
                }
            } else {
                VaultContentView(model: model)
            }
        }
        .navigationTitle("vault.title")
        .task { await unlock() }
        .onDisappear { model.lock(); unlocked = false; Previewer.purgeAll() }
    }

    private func unlock() async {
        guard !unlocked else { return }
        let result = await authenticator.authenticate(reason: String(localized: "vault.unlock.reason"))
        // Without a passcode there is nothing to ask for; the vault key still never leaves the Keychain.
        unlocked = result == .success || result == .unavailable
        denied = !unlocked
    }
}

private struct VaultContentView: View {
    @Bindable var model: VaultModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading: ProgressView().task { await model.start() }
            case .needsSetup: VaultSetupView(model: model)
            case .needsRestore: VaultRestoreView(model: model)
            case .ready: VaultListView(model: model)
            }
        }
        .alert("error.title", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(model.error?.localizedDescription ?? "")
        }
    }
}

private struct VaultSetupView: View {
    let model: VaultModel
    @State private var recoveryKey: String?
    @State private var confirmation = ""
    @State private var busy = false

    var body: some View {
        Form {
            if let recoveryKey {
                Section {
                    Text(recoveryKey)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("recoveryKeyText")
                } header: { Text("vault.recovery.title") } footer: { Text("vault.recovery.footer") }
                Section {
                    TextField("vault.recovery.retype", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("recoveryConfirmField")
                    if RecoveryKeyMatch.matches(confirmation, recoveryKey) {
                        Label("vault.recovery.confirmed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                } footer: { Text("vault.recovery.confirm.footer") }
                Section {
                    Button("vault.recovery.done") { Task { await model.finishSetup() } }
                        .disabled(!RecoveryKeyMatch.matches(confirmation, recoveryKey))
                        .accessibilityIdentifier("recoveryDoneButton")
                }
            } else {
                Section { Text("vault.setup.explain") } footer: { Text("vault.setup.footer") }
                Section {
                    Button {
                        busy = true
                        Task {
                            defer { busy = false }
                            do { recoveryKey = try await model.createVault() } catch { model.error = mapError(error) }
                        }
                    } label: {
                        if busy { ProgressView() } else { Text("vault.setup.create") }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("createVaultButton")
                }
            }
        }
    }
}

private struct VaultRestoreView: View {
    let model: VaultModel
    @State private var text = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section { Text("vault.restore.explain") } footer: { Text("vault.restore.footer") }
            Section {
                TextField("vault.restore.field", text: $text)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("restoreField")
                Button {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await model.restore(recoveryKey: text) } catch { model.error = mapError(error) }
                    }
                } label: {
                    if busy { ProgressView() } else { Text("vault.restore.button") }
                }
                .disabled(busy || text.isEmpty)
            }
        }
    }
}

private struct VaultListView: View {
    @Bindable var model: VaultModel
    @State private var showAdd = false
    @State private var preview: URL?
    @State private var grantTarget: VaultModel.PendingMember?
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            if !model.hasFamilyAccess {
                Section { Label("vault.waiting", systemImage: "hourglass") } footer: { Text("vault.waiting.footer") }
            }
            if model.rotationNeeded && model.role == .admin {
                Section {
                    Button { run { try await model.rotateFamilyKey() } } label: { Label("vault.rotate", systemImage: "arrow.triangle.2.circlepath") }
                } footer: { Text("vault.rotate.footer") }
            }
            if !model.pending.isEmpty {
                Section {
                    ForEach(model.pending) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.member.displayName).font(.headline)
                            Text(item.safetyNumber).font(.system(.footnote, design: .monospaced))
                            Button("vault.grant") { grantTarget = item }
                                .buttonStyle(.bordered)
                        }
                    }
                } header: { Text("vault.pending") } footer: { Text("vault.pending.footer") }
            }
            Section {
                if model.documents.isEmpty {
                    ContentUnavailableView("vault.empty", systemImage: "doc.badge.lock", description: Text("vault.empty.description"))
                }
                ForEach(model.documents) { document in
                    Button { run { preview = try Previewer.write(await model.open(document), name: document.metadata.fileName) } } label: {
                        HStack {
                            Image(systemName: document.isPersonal ? "person.fill.badge.lock" : "person.2.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(document.metadata.title).foregroundStyle(.primary)
                                Text("\(document.metadata.kind) · \(ByteCountFormatter.string(fromByteCount: document.sizeBytes, countStyle: .file))")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let docs = offsets.map { model.documents[$0] }
                    run { for doc in docs { try await model.delete(doc) } }
                }
            }
            if let own = model.safetyNumberOwnKey {
                Section { Text(own).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) } header: { Text("vault.ownKey") } footer: { Text("vault.ownKey.footer") }
            }
        }
        .toolbar {
            if model.hasFamilyAccess {
                Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
                    .accessibilityLabel(Text("vault.add"))
                    .accessibilityIdentifier("addVaultDocumentButton")
            }
        }
        .sheet(isPresented: $showAdd) { AddVaultDocumentView(model: model) }
        .quickLookPreview($preview)
        .onChange(of: preview) { old, new in if new == nil, let old { Previewer.remove(old) } }
        .confirmationDialog("vault.grant.confirm", isPresented: Binding(get: { grantTarget != nil }, set: { if !$0 { grantTarget = nil } }),
                            titleVisibility: .visible, presenting: grantTarget) { target in
            Button("vault.grant") { run { try await model.grantAccess(to: target) } }
        } message: { target in
            Text("vault.grant.message \(target.member.displayName)")
        }
        .refreshable { run { try await model.refresh() } }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task { do { try await work() } catch { model.error = mapError(error) } }
    }
}

private struct AddVaultDocumentView: View {
    let model: VaultModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind = "passport"
    @State private var personal = false
    @State private var picking = false
    @State private var busy = false

    private static let kinds = ["passport", "id", "contract", "medical", "tax", "other"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("vault.field.title", text: $title).accessibilityIdentifier("vaultTitleField")
                Picker("vault.field.kind", selection: $kind) {
                    ForEach(Self.kinds, id: \.self) { Text(LocalizedStringKey("vault.kind." + $0)).tag($0) }
                }
                Picker("vault.field.visibility", selection: $personal) {
                    Text("vault.visibility.family").tag(false)
                    Text("vault.visibility.personal").tag(true)
                }
                .pickerStyle(.segmented)
                Section {
                    Button("vault.choose") { picking = true }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                } footer: { Text("vault.choose.footer") }
            }
            .navigationTitle("vault.add")
            .toolbar { Button("common.cancel") { dismiss() } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
                Task { await save(result) }
            }
        }
    }

    private func save(_ result: Result<URL, Error>) async {
        busy = true
        defer { busy = false }
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Check the size first: Data(contentsOf:) loads everything, and a huge file would kill the app before
            // the model's limit applied.
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= VaultModel.maxFileBytes else { throw AppError.unknown }
            let data = try Data(contentsOf: url)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            try await model.add(file: data, title: title.trimmingCharacters(in: .whitespaces), kind: kind,
                                fileName: url.lastPathComponent, mimeType: mime, personal: personal)
            dismiss()
        } catch { model.error = mapError(error) }
    }
}

/// Plaintext touches the disk only for the preview: protected, in a private folder, deleted afterwards.
enum Previewer {
    private static var directory: URL { FileManager.default.temporaryDirectory.appending(path: "vault-preview", directoryHint: .isDirectory) }

    static func write(_ data: Data, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = URL(fileURLWithPath: name).lastPathComponent
        let url = directory.appending(path: "\(UUID().uuidString)-\(safe.isEmpty ? "document" : safe)")
        try data.write(to: url, options: [.completeFileProtection])
        return url
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    static func purgeAll() { try? FileManager.default.removeItem(at: directory) }
}
