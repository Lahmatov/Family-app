import SwiftUI

struct LockView: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("lock.title")
                .font(.title2.bold())
            Button {
                Task { await lock.unlock() }
            } label: {
                Label("lock.unlock", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("unlockButton")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// Covers the UI while the app is inactive so sensitive data never lands in the app switcher snapshot.
struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            Image(systemName: "house.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
    }
}
