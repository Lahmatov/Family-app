import FamilyCore
import Foundation
import Observation

/// Top-level navigation state. The order of gates is a security property:
/// signed in → second factor verified → member of a family → app content.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case signedOut
        case mfaEnrollment
        case mfaChallenge(factorId: String)
        case noFamily
        case ready
        case failed(AppError)
    }

    private(set) var phase: Phase = .launching
    private(set) var memberships: [Membership] = []
    private(set) var userId: UUID?
    private(set) var email: String?
    var selectedFamilyId: UUID? {
        didSet { defaults.set(selectedFamilyId?.uuidString, forKey: Self.selectedFamilyKey) }
    }

    let services: Services
    private let defaults: UserDefaults
    private static let selectedFamilyKey = "selectedFamilyId"

    init(services: Services, defaults: UserDefaults = .standard) {
        self.services = services
        self.defaults = defaults
        selectedFamilyId = defaults.string(forKey: Self.selectedFamilyKey).flatMap(UUID.init(uuidString:))
    }

    var currentMembership: Membership? {
        memberships.first { $0.family.id == selectedFamilyId } ?? memberships.first
    }

    /// Re-evaluates every gate from scratch. Safe to call at any time.
    func refresh() async {
        guard let user = await services.auth.currentUser() else {
            reset(to: .signedOut)
            return
        }
        userId = user.id
        email = user.email

        do {
            switch try await services.auth.assurance() {
            case .enrollmentRequired:
                phase = .mfaEnrollment
            case let .challengeRequired(factorId):
                phase = .mfaChallenge(factorId: factorId)
            case .verified:
                try await loadMemberships()
            }
        } catch let error as AppError {
            phase = .failed(error)
        } catch {
            phase = .failed(.unknown)
        }
    }

    func loadMemberships() async throws {
        memberships = try await services.family.memberships()
        if memberships.isEmpty {
            phase = .noFamily
        } else {
            if currentMembership?.family.id != selectedFamilyId {
                selectedFamilyId = memberships.first?.family.id
            }
            phase = .ready
        }
    }

    func signOut() async {
        await services.auth.signOut()
        reset(to: .signedOut)
    }

    private func reset(to phase: Phase) {
        memberships = []
        userId = nil
        email = nil
        self.phase = phase
    }
}
