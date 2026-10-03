import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
    @Environment(\.openURL) private var openURL
    @State private var privacy: PrivacyModel?
    @State private var exportURL: URL?
    @State private var confirmErase = false
    @State private var busy = false

    var body: some View {
        @Bindable var lock = lock
        Form {
            Section {
                LabeledContent("auth.email", value: model.email ?? "")
            }
            Section {
                Toggle(isOn: $lock.isEnabled) {
                    Label("settings.faceId", systemImage: "faceid")
                }
            } footer: {
                if lock.protectionUnavailable {
                    Text("settings.faceId.unavailable").foregroundStyle(.orange)
                } else {
                    Text("settings.faceId.footer")
                }
            }
            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label("settings.language", systemImage: "globe")
                }
            } footer: {
                Text("settings.language.footer")
            }
            Section {
                if let exportURL {
                    ShareLink(item: exportURL) { Label("settings.export.share", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("shareExportButton")
                } else {
                    Button { Task { await prepareExport() } } label: { Label("settings.export", systemImage: "doc.badge.arrow.up") }
                        .disabled(busy)
                        .accessibilityIdentifier("exportDataButton")
                }
                Button(role: .destructive) { confirmErase = true } label: { Label("settings.erase", systemImage: "trash") }
                    .disabled(busy)
                    .accessibilityIdentifier("eraseAccountButton")
            } header: { Text("settings.privacy") } footer: { Text("settings.privacy.footer") }
            Section {
                Button("settings.signOut", role: .destructive) {
                    Task { await model.signOut() }
                }
                .accessibilityIdentifier("signOutButton")
            } footer: {
                Text("settings.signOut.footer")
            }
        }
        .navigationTitle("tab.settings")
        .onAppear { if privacy == nil { privacy = PrivacyModel(service: model.services.privacy) } }
        .onDisappear { removeExportFile() }
        .confirmationDialog("settings.erase.confirm", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("settings.erase.action", role: .destructive) { Task { await erase() } }
        } message: { Text("settings.erase.message") }
        .alert("settings.erase.blocked", isPresented: Binding(get: { !(privacy?.blockers.isEmpty ?? true) },
                                                              set: { if !$0 { privacy?.clearBlockers() } })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("settings.erase.blocked.message \((privacy?.blockers.map(\.name) ?? []).joined(separator: ", "))")
        }
        .alert("error.title", isPresented: Binding(get: { privacy?.error != nil }, set: { if !$0 { privacy?.error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(privacy?.error?.localizedDescription ?? "")
        }
    }

    private func prepareExport() async {
        guard let privacy, await confirmDevice(String(localized: "settings.export.reason")) else { return }
        busy = true
        defer { busy = false }
        exportURL = await privacy.export()
    }

    private func erase() async {
        guard let privacy, await confirmDevice(String(localized: "settings.erase.reason")) else { return }
        busy = true
        defer { busy = false }
        if await privacy.erase() { await model.signOut() }
    }

    private func confirmDevice(_ reason: String) async -> Bool {
        let result = await makeDeviceAuthenticator().authenticate(reason: reason)
        return result != .failed
    }

    private func removeExportFile() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil
    }
}
