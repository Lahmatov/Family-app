import SwiftUI

@main
struct FamilyApp: App {
    @State private var model: AppModel
    @State private var lock: AppLock
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let services = Services.make(arguments: arguments)
        if arguments.contains("-ui-testing") {
            // Fresh, isolated state for every UI test run; no biometric prompt.
            let defaults = UserDefaults(suiteName: "ui-testing")!
            defaults.removePersistentDomain(forName: "ui-testing")
            defaults.set(false, forKey: "appLockEnabled")
            _model = State(initialValue: AppModel(services: services, defaults: defaults))
            _lock = State(initialValue: AppLock(defaults: defaults))
        } else {
            _model = State(initialValue: AppModel(services: services))
            _lock = State(initialValue: AppLock())
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                if lock.isLocked && model.phase != .signedOut {
                    LockView(lock: lock)
                        .transition(.opacity)
                }
                if lock.isObscured {
                    PrivacyShield()
                }
            }
            .environment(model)
            .environment(lock)
            .task { await model.refresh() }
            .onOpenURL { url in
                Task {
                    try? await model.services.auth.handleDeepLink(url)
                    await model.refresh()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: lock.didEnterBackground()
            case .inactive: lock.willResignActive()
            case .active: Task { await lock.didBecomeActive() }
            @unknown default: break
            }
        }
    }
}
