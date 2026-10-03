import Foundation

/// Mirrors `public.loan_type`.
public enum LoanType: String, Codable, Sendable, CaseIterable {
    case annuity
    case differentiated
}

/// Mirrors `public.extra_strategy`.
public enum ExtraStrategy: String, Codable, Sendable, CaseIterable {
    /// Keep the instalment, finish earlier.
    case reduceTerm = "reduce_term"
    /// Keep the end date, pay less each month.
    case reducePayment = "reduce_payment"
}

public struct LoanTerms: Hashable, Sendable {
    /// Minor units (cents).
    public let principal: Int64
    /// Nominal annual rate in percent, e.g. 3.6.
    public let annualRate: Decimal
    public let termMonths: Int
    public let firstPaymentOn: LocalDate
    public let type: LoanType

    public init(principal: Int64, annualRate: Decimal, termMonths: Int, firstPaymentOn: LocalDate, type: LoanType) {
        self.principal = principal
        self.annualRate = annualRate
        self.termMonths = termMonths
        self.firstPaymentOn = firstPaymentOn
        self.type = type
    }
}

/// A new rate that applies from the first instalment due on or after `effectiveFrom`
/// (variable-rate loans, e.g. Euribor reviews).
public struct RateChange: Hashable, Sendable {
    public let effectiveFrom: LocalDate
    public let annualRate: Decimal

    public init(effectiveFrom: LocalDate, annualRate: Decimal) {
        self.effectiveFrom = effectiveFrom
        self.annualRate = annualRate
    }
}

public struct ExtraPayment: Hashable, Sendable {
    public let on: LocalDate
    public let amount: Int64
    public let strategy: ExtraStrategy

    public init(on: LocalDate, amount: Int64, strategy: ExtraStrategy) {
        self.on = on
        self.amount = amount
        self.strategy = strategy
    }
}

public struct Installment: Hashable, Sendable {
    public let number: Int
    public let dueOn: LocalDate
    /// Regular payment (interest + principal), without extra payments.
    public let payment: Int64
    public let interest: Int64
    public let principal: Int64
    /// Extra payments applied right before this instalment.
    public let extra: Int64
    public let balanceAfter: Int64
}

public struct LoanSchedule: Equatable, Sendable {
    public let installments: [Installment]

    public var totalInterest: Int64 { installments.reduce(0) { $0 + $1.interest } }
    public var totalPaid: Int64 { installments.reduce(0) { $0 + $1.payment + $1.extra } }
    public var payoffDate: LocalDate? { installments.last?.dueOn }
}

public struct LoanStatus: Equatable, Sendable {
    public let paidCount: Int
    public let remainingBalance: Int64
    public let next: Installment?
    /// Unpaid instalments whose due date is before today.
    public let overdue: [Installment]
}

public enum LoanCalculator {
    /// Interest accrues monthly at annualRate / 12 on the balance after any extra payment of that
    /// month (extra payments are applied right before the instalment). Every amount is rounded
    /// half away from zero to a minor unit, and the last instalment absorbs the rounding remainder.
    public static func schedule(
        _ terms: LoanTerms, rateChanges: [RateChange] = [], extras: [ExtraPayment] = []
    ) -> LoanSchedule {
        guard terms.principal > 0, terms.termMonths > 0 else { return LoanSchedule(installments: []) }

        let changes = rateChanges.sorted { $0.effectiveFrom < $1.effectiveFrom }
        let sortedExtras = extras.sorted { $0.on < $1.on }

        var balance = terms.principal
        var rate = terms.annualRate
        var remaining = terms.termMonths
        var payment = terms.type == .annuity ? annuityPayment(balance, rate, remaining) : 0
        var principalPart = terms.type == .differentiated ? roundMinor(Decimal(balance) / Decimal(remaining)) : 0
        var rows: [Installment] = []

        for number in 1...terms.termMonths {
            guard let due = terms.firstPaymentOn.adding(months: number - 1) else { break }
            let previousDue = number == 1 ? nil : terms.firstPaymentOn.adding(months: number - 2)

            if let current = changes.last(where: { $0.effectiveFrom <= due })?.annualRate, current != rate {
                rate = current
                if terms.type == .annuity { payment = annuityPayment(balance, rate, remaining) }
            }

            var extraTotal: Int64 = 0
            for extra in sortedExtras where extra.on <= due && (previousDue.map { extra.on > $0 } ?? true) {
                let applied = min(extra.amount, balance)
                guard applied > 0 else { continue }
                balance -= applied
                extraTotal += applied
                if extra.strategy == .reducePayment, balance > 0 {
                    switch terms.type {
                    case .annuity: payment = annuityPayment(balance, rate, remaining)
                    case .differentiated: principalPart = roundMinor(Decimal(balance) / Decimal(remaining))
                    }
                }
            }

            if balance == 0 {
                rows.append(Installment(number: number, dueOn: due, payment: 0, interest: 0, principal: 0,
                                        extra: extraTotal, balanceAfter: 0))
                break
            }

            let interest = roundMinor(Decimal(balance) * rate / 1200)
            let principal: Int64
            switch terms.type {
            case .annuity:
                principal = remaining == 1 ? balance : min(max(payment - interest, 0), balance)
            case .differentiated:
                principal = remaining == 1 ? balance : min(principalPart, balance)
            }
            balance -= principal
            remaining -= 1
            rows.append(Installment(number: number, dueOn: due, payment: principal + interest, interest: interest,
                                    principal: principal, extra: extraTotal, balanceAfter: balance))
            if balance == 0 { break }
        }
        return LoanSchedule(installments: rows)
    }

    /// Interest saved by the extra payments compared with the same loan without them.
    public static func interestSaved(
        _ terms: LoanTerms, rateChanges: [RateChange] = [], extras: [ExtraPayment]
    ) -> Int64 {
        let baseline = schedule(terms, rateChanges: rateChanges).totalInterest
        return baseline - schedule(terms, rateChanges: rateChanges, extras: extras).totalInterest
    }

    /// Where the loan stands, given the numbers of the instalments marked as paid.
    public static func status(_ schedule: LoanSchedule, paid: Set<Int>, today: LocalDate) -> LoanStatus {
        let rows = schedule.installments
        let lastPaid = rows.last { paid.contains($0.number) }
        // A settlement row (the balance was cleared by an extra payment) has nothing left to pay.
        let unpaid = rows.filter { !paid.contains($0.number) && $0.payment > 0 }
        // Extras recorded before the first unpaid instalment already reduced the balance.
        let balance = unpaid.first.map { first in
            (rows.first { $0.number == first.number - 1 }?.balanceAfter ?? principalOf(rows)) - first.extra
        } ?? 0
        return LoanStatus(
            paidCount: paid.intersection(Set(rows.map(\.number))).count,
            remainingBalance: lastPaid == nil && unpaid.isEmpty ? 0 : max(balance, 0),
            next: unpaid.first,
            overdue: unpaid.filter { $0.dueOn < today }
        )
    }

    /// Fixed instalment of an annuity: B·r / (1 − (1 + r)^−n), r = monthly rate.
    public static func annuityPayment(_ balance: Int64, _ annualRate: Decimal, _ months: Int) -> Int64 {
        guard balance > 0, months > 0 else { return 0 }
        let r = annualRate / 1200
        if r == 0 { return roundMinor(Decimal(balance) / Decimal(months)) }
        var growth = Decimal(1)
        for _ in 0..<months { growth *= (1 + r) }
        return roundMinor(Decimal(balance) * r / (1 - 1 / growth))
    }

    private static func principalOf(_ rows: [Installment]) -> Int64 {
        rows.reduce(0) { $0 + $1.principal + $1.extra }
    }

    private static func roundMinor(_ value: Decimal) -> Int64 {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 0, .plain)
        return NSDecimalNumber(decimal: output).int64Value
    }
}
