import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView()
            case .signedOut:
                SignInView()
            case .mfaEnrollment:
                MFAEnrollView()
            case let .mfaChallenge(factorId):
                MFAChallengeView(factorId: factorId)
            case .noFamily:
                NoFamilyView()
            case .ready:
                MainTabView()
            case let .failed(error):
                ErrorStateView(error: error)
            }
        }
        .animation(.default, value: model.phase)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            BudgetHomeView()
                .tabItem { Label("tab.budget", systemImage: "eurosign.circle") }
            FamilyView()
                .tabItem { Label("tab.family", systemImage: "person.3") }
            SettingsView()
                .tabItem { Label("tab.settings", systemImage: "gearshape") }
        }
    }
}

struct ErrorStateView: View {
    @Environment(AppModel.self) private var model
    let error: AppError

    var body: some View {
        ContentUnavailableView {
            Label("error.title", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            Button("common.retry") { Task { await model.refresh() } }
                .buttonStyle(.borderedProminent)
            Button("settings.signOut", role: .destructive) { Task { await model.signOut() } }
        }
    }
}

/// Small helper: runs an async action, tracks progress, surfaces errors.
@MainActor
@Observable
final class AsyncAction {
    private(set) var isRunning = false
    var error: AppError?

    func run(_ operation: @MainActor () async throws -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            try await operation()
            error = nil
        } catch let appError as AppError {
            error = appError
        } catch {
            self.error = .unknown
        }
    }
}

extension View {
    func errorAlert(_ action: AsyncAction) -> some View {
        alert(
            "error.title",
            isPresented: Binding(get: { action.error != nil }, set: { if !$0 { action.error = nil } }),
            presenting: action.error
        ) { _ in
            Button("common.ok", role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
    }
}
