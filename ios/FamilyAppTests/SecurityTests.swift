import FamilyCore
import ImageIO
import UIKit
import XCTest
@testable import FamilyApp

private final class StubAuthenticator: DeviceAuthenticating, @unchecked Sendable {
    var result: DeviceAuthResult
    private(set) var calls = 0
    init(result: DeviceAuthResult) { self.result = result }
    func authenticate(reason: String) async -> DeviceAuthResult {
        calls += 1
        return result
    }
}

@MainActor
final class AppLockTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 0)
    }

    private let clock = Clock()

    private var defaults: UserDefaults {
        UserDefaults(suiteName: "AppLockTests-\(name)")!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: "AppLockTests-\(name)")
        super.tearDown()
    }

    private func makeLock(_ auth: StubAuthenticator) -> AppLock {
        let clock = clock
        return AppLock(authenticator: auth, defaults: defaults, gracePeriod: 30, now: { clock.now })
    }

    func testLockedOnLaunchAndUnlocksWithBiometrics() async {
        let auth = StubAuthenticator(result: .success)
        let lock = makeLock(auth)
        XCTAssertTrue(lock.isLocked, "the app starts locked")
        await lock.didBecomeActive()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(auth.calls, 1)
    }

    func testFailedBiometricsKeepsLock() async {
        let lock = makeLock(StubAuthenticator(result: .failed))
        await lock.didBecomeActive()
        XCTAssertTrue(lock.isLocked)
    }

    func testRelocksAfterGracePeriodOnly() async {
        let auth = StubAuthenticator(result: .success)
        let lock = makeLock(auth)
        await lock.didBecomeActive()

        lock.didEnterBackground()
        XCTAssertTrue(lock.isObscured, "content hidden for the app switcher snapshot")
        clock.now += 10
        auth.result = .failed
        await lock.didBecomeActive()
        XCTAssertFalse(lock.isLocked, "short switch away does not re-lock")
        XCTAssertFalse(lock.isObscured)

        lock.didEnterBackground()
        clock.now += 31
        await lock.didBecomeActive()
        XCTAssertTrue(lock.isLocked, "re-locks after the grace period")
    }

    func testDeviceWithoutPasscodeDoesNotLockTheOwnerOut() async {
        let lock = makeLock(StubAuthenticator(result: .unavailable))
        XCTAssertFalse(lock.protectionUnavailable)
        await lock.didBecomeActive()
        XCTAssertFalse(lock.isLocked, "no passcode on the device: locking would be permanent")
        XCTAssertTrue(lock.protectionUnavailable, "the UI can warn that the lock has no effect")
    }

    func testDisablingLockPersists() {
        let lock = makeLock(StubAuthenticator(result: .success))
        lock.isEnabled = false
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(makeLock(StubAuthenticator(result: .success)).isLocked)
    }
}

final class ConfigurationTests: XCTestCase {
    func testOnlyHttpsOrLocalhost() {
        XCTAssertTrue(SupabaseClientFactory.isAllowed(URL(string: "https://abc.supabase.co")!))
        XCTAssertFalse(SupabaseClientFactory.isAllowed(URL(string: "http://abc.supabase.co")!))
        XCTAssertFalse(SupabaseClientFactory.isAllowed(URL(string: "ftp://abc.supabase.co")!))
        XCTAssertFalse(SupabaseClientFactory.isAllowed(URL(string: "https://")!))
        #if DEBUG
        XCTAssertTrue(SupabaseClientFactory.isAllowed(URL(string: "http://127.0.0.1:54321")!))
        #endif
    }

    func testErrorMappingNeverLeaksServerText() {
        struct ServerError: Error, CustomStringConvertible {
            let description: String
        }
        XCTAssertEqual(mapError(ServerError(description: "code 42501 permission denied for table secrets")), .forbidden)
        XCTAssertEqual(mapError(ServerError(description: "P0002 invitation not found")), .notFound)
        XCTAssertEqual(mapError(URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(mapError(ServerError(description: "internal stack trace ...")), .unknown)
    }

    func testPasswordPolicyMatchesServer() {
        XCTAssertEqual(PasswordPolicy.issues(for: "Correct-Horse-1"), [])
        XCTAssertTrue(PasswordPolicy.issues(for: "short1A").contains(.tooShort))
        XCTAssertTrue(PasswordPolicy.issues(for: "alllowercase123").contains(.noUppercase))
        XCTAssertTrue(PasswordPolicy.issues(for: "ALLUPPERCASE123").contains(.noLowercase))
        XCTAssertTrue(PasswordPolicy.issues(for: "NoDigitsHereAtAll").contains(.noDigit))
    }
}

final class ReceiptProcessorTests: XCTestCase {
    func testDownscalesAndStripsMetadata() throws {
        let size = CGSize(width: 4000, height: 3000)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let upload = try XCTUnwrap(ReceiptProcessor.process(image))
        XCTAssertEqual(upload.mimeType, "image/jpeg")
        let decoded = try XCTUnwrap(UIImage(data: upload.data))
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), ReceiptProcessor.maxDimension)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(upload.data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "no GPS metadata leaves the device")
    }
}


final class SessionStorageTests: XCTestCase {
    func testRoundTripReplaceAndRemove() throws {
        let storage = DeviceOnlyKeychainStorage(service: "app.family.tests.\(UUID().uuidString)")
        // Keychain calls stay outside the XCTAssert autoclosures so that a missing keychain
        // (unsigned CI host, status -34018) skips the test instead of failing it.
        let initial, afterStore, afterReplace, afterRemove: Data?
        do {
            initial = try storage.retrieve(key: "session")
            try storage.store(key: "session", value: Data("one".utf8))
            afterStore = try storage.retrieve(key: "session")
            try storage.store(key: "session", value: Data("two".utf8))
            afterReplace = try storage.retrieve(key: "session")
            try storage.remove(key: "session")
            afterRemove = try storage.retrieve(key: "session")
            try storage.remove(key: "session") // removing a missing item is not an error
        } catch let failure as DeviceOnlyKeychainStorage.Failure {
            throw XCTSkip("Keychain is not available in this test host (status \(failure.status))")
        }
        XCTAssertNil(initial)
        XCTAssertEqual(afterStore, Data("one".utf8))
        XCTAssertEqual(afterReplace, Data("two".utf8), "store replaces")
        XCTAssertNil(afterRemove)
    }
}
