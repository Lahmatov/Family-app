import Foundation

/// What stands in the way of erasing the account and which stored files have to be removed first.
struct ErasurePlan: Decodable, Sendable, Equatable {
    struct Blocker: Decodable, Sendable, Equatable { let name: String }
    struct File: Decodable, Sendable, Equatable { let bucket: String; let name: String }
    let blockers: [Blocker]
    let files: [File]
}
