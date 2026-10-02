import FamilyCore
import ImageIO
import UIKit
import XCTest
@testable import FamilyApp

private final class StubAuthenticator: DeviceAuthenticating, @unchecked Sendable {
    var result: Bool
    private(set) var calls = 0
    init(result: Bool) { self.result = result }
    func authenticate(reason: String) async -> Bool {
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
        let auth = StubAuthenticator(result: true)
        let lock = makeLock(auth)
        XCTAssertTrue(lock.isLocked, "the app starts locked")
        await lock.didBecomeActive()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(auth.calls, 1)
    }

    func testFailedBiometricsKeepsLock() async {
        let lock = makeLock(StubAuthenticator(result: false))
        await lock.didBecomeActive()
        XCTAssertTrue(lock.isLocked)
    }

    func testRelocksAfterGracePeriodOnly() async {
        let auth = StubAuthenticator(result: true)
        let lock = makeLock(auth)
        await lock.didBecomeActive()

        lock.didEnterBackground()
        XCTAssertTrue(lock.isObscured, "content hidden for the app switcher snapshot")
        clock.now += 10
        auth.result = false
        await lock.didBecomeActive()
        XCTAssertFalse(lock.isLocked, "short switch away does not re-lock")
        XCTAssertFalse(lock.isObscured)

        lock.didEnterBackground()
        clock.now += 31
        await lock.didBecomeActive()
        XCTAssertTrue(lock.isLocked, "re-locks after the grace period")
    }

    func testDisablingLockPersists() {
        let lock = makeLock(StubAuthenticator(result: true))
        lock.isEnabled = false
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(makeLock(StubAuthenticator(result: true)).isLocked)
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
