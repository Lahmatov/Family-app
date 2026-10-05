import Foundation
import XCTest
@testable import FamilyCore

final class MemberRoleTests: XCTestCase {
    func testOrdering() {
        XCTAssertTrue(MemberRole.admin > .adult)
        XCTAssertTrue(MemberRole.adult > .child)
        XCTAssertTrue(MemberRole.child > .guest)
        XCTAssertTrue(MemberRole.adult.isAtLeast(.adult))
        XCTAssertFalse(MemberRole.child.isAtLeast(.adult))
    }

    /// Mirrors the RLS matrix in docs/03-roles.md and supabase/tests/030_budget.test.sql.
    func testFinanceMatrix() {
        XCTAssertTrue(MemberRole.admin.can(.viewFinance))
        XCTAssertTrue(MemberRole.adult.can(.viewFinance))
        XCTAssertFalse(MemberRole.child.can(.viewFinance))
        XCTAssertFalse(MemberRole.guest.can(.viewFinance))

        XCTAssertTrue(MemberRole.admin.can(.manageBudgets))
        XCTAssertFalse(MemberRole.adult.can(.manageBudgets))
        XCTAssertFalse(MemberRole.adult.can(.editOthersTransactions))
    }

    func testOnlyAdminsHandleCriticalActions() {
        for role in MemberRole.allCases {
            XCTAssertEqual(role.can(.approveCriticalActions), role == .admin)
            XCTAssertEqual(role.can(.requestCriticalActions), role == .admin)
            XCTAssertEqual(role.can(.viewAuditLog), role == .admin)
        }
    }

    func testEveryoneSeesFamily() {
        XCTAssertTrue(MemberRole.allCases.allSatisfy { $0.can(.viewFamily) })
    }

    func testRawValuesMatchDatabaseEnum() {
        XCTAssertEqual(MemberRole.allCases.map(\.rawValue), ["admin", "adult", "child", "guest"])
        XCTAssertEqual(ApprovalAction.allCases.map(\.rawValue),
                       ["invite_member", "remove_member", "change_role", "delete_family"])
    }
}

final class ApprovalPolicyTests: XCTestCase {
    let alice = UUID()
    let anna = UUID()
    let future = Date().addingTimeInterval(3600)

    func testSecondAdminRequirement() {
        XCTAssertFalse(ApprovalPolicy.requiresSecondAdmin(adminCount: 1))
        XCTAssertTrue(ApprovalPolicy.requiresSecondAdmin(adminCount: 2))
    }

    func testCanApprove() {
        XCTAssertEqual(ApprovalPolicy.canApprove(approverId: anna, approverRole: .admin, requestedBy: alice,
                                                 status: .pending, expiresAt: future), .allowed)
        XCTAssertEqual(ApprovalPolicy.canApprove(approverId: alice, approverRole: .admin, requestedBy: alice,
                                                 status: .pending, expiresAt: future), .ownRequest)
        XCTAssertEqual(ApprovalPolicy.canApprove(approverId: anna, approverRole: .adult, requestedBy: alice,
                                                 status: .pending, expiresAt: future), .notAnAdmin)
        XCTAssertEqual(ApprovalPolicy.canApprove(approverId: anna, approverRole: nil, requestedBy: alice,
                                                 status: .pending, expiresAt: future), .notAnAdmin)
        XCTAssertEqual(ApprovalPolicy.canApprove(approverId: anna, approverRole: .admin, requestedBy: alice,
                                                 status: .executed, expiresAt: future), .notPending)
        XCTAssertEqual(ApprovalPolicy.canApprove(approverId: anna, approverRole: .admin, requestedBy: alice,
                                                 status: .pending, expiresAt: Date().addingTimeInterval(-1)), .expired)
    }

    func testLastAdminProtection() {
        XCTAssertTrue(ApprovalPolicy.leavesNoAdmin(targetCurrentRole: .admin, newRole: .adult, adminCount: 1))
        XCTAssertTrue(ApprovalPolicy.leavesNoAdmin(targetCurrentRole: .admin, newRole: nil, adminCount: 1))
        XCTAssertFalse(ApprovalPolicy.leavesNoAdmin(targetCurrentRole: .admin, newRole: .adult, adminCount: 2))
        XCTAssertFalse(ApprovalPolicy.leavesNoAdmin(targetCurrentRole: .adult, newRole: nil, adminCount: 1))
    }
}

final class LocalDateTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(LocalDate("2026-10-02"), LocalDate(year: 2026, month: 10, day: 2))
        XCTAssertNil(LocalDate("2026-02-30"))
        XCTAssertNil(LocalDate("2026-2-3"))
        XCTAssertNil(LocalDate("garbage"))
        XCTAssertNotNil(LocalDate("2024-02-29"))
        XCTAssertNil(LocalDate("2100-02-29"))
        XCTAssertNotNil(LocalDate("2000-02-29"))
    }

    func testCodableRoundTrip() throws {
        let date = LocalDate(year: 2026, month: 1, day: 5)!
        let data = try JSONEncoder().encode([date])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["2026-01-05"]"#)
        XCTAssertEqual(try JSONDecoder().decode([LocalDate].self, from: data), [date])
    }

    func testFromDateUsesTimeZone() {
        // 2026-10-01T23:30:00Z is already Oct 2 in Lisbon (UTC+1 in summer time).
        let instant = Date(timeIntervalSince1970: 1_790_897_400)
        XCTAssertEqual(LocalDate(instant, timeZone: TimeZone(identifier: "UTC")!).description, "2026-10-01")
        XCTAssertEqual(LocalDate(instant, timeZone: TimeZone(identifier: "Europe/Lisbon")!).description, "2026-10-02")
    }

    func testYearMonth() {
        let month = YearMonth(year: 2026, month: 12)!
        XCTAssertEqual(month.adding(months: 1).description, "2027-01")
        XCTAssertEqual(month.adding(months: -12).description, "2025-12")
        XCTAssertEqual(YearMonth(year: 2028, month: 2)!.numberOfDays, 29)
        XCTAssertTrue(month.contains(LocalDate("2026-12-31")!))
        XCTAssertFalse(month.contains(LocalDate("2027-12-31")!))
    }
}
