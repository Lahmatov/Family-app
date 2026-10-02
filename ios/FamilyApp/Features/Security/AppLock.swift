import Foundation
import LocalAuthentication
import Observation

/// Abstraction over LocalAuthentication so the lock logic is unit-testable.
protocol DeviceAuthenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

struct LocalDeviceAuthenticator: DeviceAuthenticating {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        // Face ID / Touch ID with device passcode fallback.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set on the device: we cannot protect the app locally.
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Locks the UI with Face ID when the app returns from background.
@MainActor
@Observable
final class AppLock {
    /// Whether the content is currently hidden behind the lock screen.
    private(set) var isLocked: Bool
    /// Hide content while the app is inactive so the app switcher snapshot shows nothing.
    private(set) var isObscured = false

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { isLocked = false }
        }
    }

    /// Re-lock only after this long in background (0 = always).
    let gracePeriod: TimeInterval
    private var backgroundedAt: Date?
    private var isAuthenticating = false
    private let authenticator: any DeviceAuthenticating
    private let defaults: UserDefaults
    private let now: () -> Date
    private static let enabledKey = "appLockEnabled"

    init(authenticator: any DeviceAuthenticating = LocalDeviceAuthenticator(),
         defaults: UserDefaults = .standard,
         gracePeriod: TimeInterval = 30,
         now: @escaping () -> Date = Date.init) {
        self.authenticator = authenticator
        self.defaults = defaults
        self.gracePeriod = gracePeriod
        self.now = now
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.isEnabled = enabled
        self.isLocked = enabled
    }

    func didEnterBackground() {
        backgroundedAt = now()
        isObscured = true
    }

    func willResignActive() {
        isObscured = true
    }

    func didBecomeActive() async {
        isObscured = false
        guard isEnabled else { return }
        if let backgroundedAt, now().timeIntervalSince(backgroundedAt) >= gracePeriod {
            isLocked = true
        }
        backgroundedAt = nil
        if isLocked { await unlock() }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await authenticator.authenticate(reason: String(localized: "lock.reason")) {
            isLocked = false
        }
    }
}
