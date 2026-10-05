import Foundation
import LocalAuthentication
import Observation

enum DeviceAuthResult: Equatable, Sendable {
    case success
    case failed
    /// The device has no passcode / biometrics, so no local lock is possible.
    case unavailable
}

/// Abstraction over LocalAuthentication so the lock logic is unit-testable.
protocol DeviceAuthenticating: Sendable {
    func authenticate(reason: String) async -> DeviceAuthResult
}

struct LocalDeviceAuthenticator: DeviceAuthenticating {
    func authenticate(reason: String) async -> DeviceAuthResult {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        // Face ID / Touch ID with device passcode fallback.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Without a passcode anyone holding the phone is already inside; locking the
            // app would only lock the owner out for good.
            return .unavailable
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
        } catch {
            return .failed
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
    /// True when the device cannot authenticate the owner; the lock is then ineffective.
    private(set) var protectionUnavailable = false

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
        switch await authenticator.authenticate(reason: String(localized: "lock.reason")) {
        case .success:
            isLocked = false
            protectionUnavailable = false
        case .unavailable:
            isLocked = false
            protectionUnavailable = true
        case .failed:
            break
        }
    }
}

/// Real LocalAuthentication, except in debug UI tests where nobody can touch Face ID.
func makeDeviceAuthenticator() -> any DeviceAuthenticating {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-ui-testing") { return AlwaysAuthenticator() }
    #endif
    return LocalDeviceAuthenticator()
}

#if DEBUG
private struct AlwaysAuthenticator: DeviceAuthenticating {
    func authenticate(reason: String) async -> DeviceAuthResult { .success }
}
#endif
