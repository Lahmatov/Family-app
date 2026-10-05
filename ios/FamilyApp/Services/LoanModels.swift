import FamilyCore
import Foundation

struct Loan: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let familyId: UUID
    var title: String
    var lender: String?
    let principalMinor: Int64
    let currency: CurrencyCode
    let annualRate: Decimal
    let termMonths: Int
    let firstPaymentOn: LocalDate
    let loanType: LoanType

    var terms: LoanTerms {
        LoanTerms(principal: principalMinor, annualRate: annualRate, termMonths: termMonths,
                  firstPaymentOn: firstPaymentOn, type: loanType)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, lender, currency
        case familyId = "family_id"
        case principalMinor = "principal_minor"
        case annualRate = "annual_rate"
        case termMonths = "term_months"
        case firstPaymentOn = "first_payment_on"
        case loanType = "loan_type"
    }
}

struct LoanRateChangeRow: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let loanId: UUID
    let effectiveFrom: LocalDate
    let annualRate: Decimal

    enum CodingKeys: String, CodingKey {
        case id
        case loanId = "loan_id"
        case effectiveFrom = "effective_from"
        case annualRate = "annual_rate"
    }
}

struct LoanExtraRow: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let loanId: UUID
    let paidOn: LocalDate
    let amountMinor: Int64
    let strategy: ExtraStrategy

    enum CodingKeys: String, CodingKey {
        case id, strategy
        case loanId = "loan_id"
        case paidOn = "paid_on"
        case amountMinor = "amount_minor"
    }
}

struct LoanPaidRow: Codable, Hashable, Sendable {
    let loanId: UUID
    let installmentNo: Int
    let paidOn: LocalDate

    enum CodingKeys: String, CodingKey {
        case loanId = "loan_id"
        case installmentNo = "installment_no"
        case paidOn = "paid_on"
    }
}

struct NewLoan: Sendable {
    var title: String
    var lender: String?
    var principalMinor: Int64
    var currency: CurrencyCode
    var annualRate: Decimal
    var termMonths: Int
    var firstPaymentOn: LocalDate
    var type: LoanType
}

/// What the loan screens need, computed from the stored rows.
struct LoanOverview: Sendable {
    let loan: Loan
    let schedule: LoanSchedule
    let status: LoanStatus
    let interestSaved: Int64
    var progress: Double {
        loan.principalMinor > 0 ? 1 - Double(status.remainingBalance) / Double(loan.principalMinor) : 0
    }
}
