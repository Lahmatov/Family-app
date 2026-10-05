import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView()
            case .signedOut:
                SignInView().readableWidth()
            case .mfaEnrollment:
                MFAEnrollView().readableWidth()
            case let .mfaChallenge(factorId):
                MFAChallengeView(factorId: factorId).readableWidth()
            case .noFamily:
                NoFamilyView().readableWidth()
            case .ready:
                MainNavigation()
            case let .failed(error):
                ErrorStateView(error: error)
            }
        }
        .animation(.default, value: model.phase)
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

extension View {
    /// Keeps forms at a comfortable width on iPad and in landscape instead of stretching edge to edge.
    func readableWidth(_ width: CGFloat = 640) -> some View {
        frame(maxWidth: width)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}
