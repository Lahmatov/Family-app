import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var lock = lock
        NavigationStack {
            Form {
                Section {
                    LabeledContent("auth.email", value: model.email ?? "")
                }
                Section {
                    Toggle(isOn: $lock.isEnabled) {
                        Label("settings.faceId", systemImage: "faceid")
                    }
                } footer: {
                    Text("settings.faceId.footer")
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
                    Button("settings.signOut", role: .destructive) {
                        Task { await model.signOut() }
                    }
                    .accessibilityIdentifier("signOutButton")
                } footer: {
                    Text("settings.signOut.footer")
                }
            }
            .navigationTitle("tab.settings")
        }
    }
}
