import Foundation
import Observation

/// GDPR actions: export of the person's data and erasure of the account.
@MainActor
@Observable
final class PrivacyModel {
    private(set) var blockers: [ErasurePlan.Blocker] = []
    var error: AppError?

    private let service: any PrivacyServicing

    init(service: any PrivacyServicing) {
        self.service = service
    }

    func clearBlockers() { blockers = [] }

    /// Writes the export into a protected temporary file the share sheet can hand over.
    func export() async -> URL? {
        do {
            let data = try await service.exportData()
            let url = FileManager.default.temporaryDirectory.appending(path: "family-data-export.json")
            try data.write(to: url, options: [.completeFileProtection])
            return url
        } catch {
            self.error = (error as? AppError) ?? .unknown
            return nil
        }
    }

    /// Removes stored files, then the account. Returns false when the person has to hand over admin rights first
    /// (see `blockers`) or something failed (see `error`).
    func erase() async -> Bool {
        do {
            let plan = try await service.erasurePlan()
            blockers = plan.blockers
            guard plan.blockers.isEmpty else { return false }
            try await service.removeFiles(plan.files)
            try await service.deleteAccount()
            return true
        } catch {
            self.error = (error as? AppError) ?? .unknown
            return false
        }
    }
}
