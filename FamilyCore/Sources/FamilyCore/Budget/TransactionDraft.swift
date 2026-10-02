import Foundation

/// User input for a new or edited transaction, validated before it is sent.
/// Limits mirror the CHECK constraints on `public.transactions`.
public struct TransactionDraft: Sendable, Equatable {
    public var kind: TransactionKind
    public var amountText: String
    public var currency: CurrencyCode
    /// Units of base currency per 1 unit of `currency`; ignored for the base currency.
    public var fxRate: Decimal?
    public var categoryId: UUID?
    public var occurredOn: LocalDate
    public var merchant: String
    public var note: String
    public var paidBy: UUID?
    public var isPrivate: Bool

    public init(kind: TransactionKind = .expense, amountText: String = "", currency: CurrencyCode,
                fxRate: Decimal? = nil, categoryId: UUID? = nil, occurredOn: LocalDate,
                merchant: String = "", note: String = "", paidBy: UUID? = nil, isPrivate: Bool = false) {
        self.kind = kind
        self.amountText = amountText
        self.currency = currency
        self.fxRate = fxRate
        self.categoryId = categoryId
        self.occurredOn = occurredOn
        self.merchant = merchant
        self.note = note
        self.paidBy = paidBy
        self.isPrivate = isPrivate
    }

    public static let maxMerchantLength = 120
    public static let maxNoteLength = 2000
    public static let maxAmountMinor: Int64 = 100_000_000_000 - 1
    static let minDate = LocalDate(year: 2000, month: 1, day: 1)!
    static let maxDate = LocalDate(year: 2100, month: 1, day: 1)!

    public enum ValidationError: Error, Equatable, Sendable {
        case amountMissing
        case amountInvalid
        case amountNotPositive
        case amountTooLarge
        case categoryMissing
        case fxRateMissing
        case fxRateInvalid
        case merchantTooLong
        case noteTooLong
        case dateOutOfRange
    }

    /// Valid payload for insert into `public.transactions`.
    public struct Validated: Equatable, Sendable {
        public let kind: TransactionKind
        public let amount: Money
        public let fxRate: Decimal
        /// Preview of the server-computed base amount.
        public let amountInBase: Money
        public let categoryId: UUID
        public let occurredOn: LocalDate
        public let merchant: String?
        public let note: String?
        public let paidBy: UUID?
        public let isPrivate: Bool
    }

    public func validate(baseCurrency: CurrencyCode) -> Result<Validated, ValidationError> {
        let amount: Money
        do {
            amount = try Money(parsing: amountText, currency: currency)
        } catch Money.ParseError.empty {
            return .failure(.amountMissing)
        } catch Money.ParseError.outOfRange {
            return .failure(.amountTooLarge)
        } catch {
            return .failure(.amountInvalid)
        }
        guard amount.minorUnits > 0 else { return .failure(.amountNotPositive) }
        guard amount.minorUnits <= Self.maxAmountMinor else { return .failure(.amountTooLarge) }
        guard let categoryId else { return .failure(.categoryMissing) }
        guard occurredOn >= Self.minDate, occurredOn <= Self.maxDate else { return .failure(.dateOutOfRange) }

        let merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard merchant.count <= Self.maxMerchantLength else { return .failure(.merchantTooLong) }
        guard note.count <= Self.maxNoteLength else { return .failure(.noteTooLong) }

        let rate: Decimal
        if currency == baseCurrency {
            rate = 1
        } else {
            guard let fxRate else { return .failure(.fxRateMissing) }
            guard fxRate > 0, fxRate < 1_000_000 else { return .failure(.fxRateInvalid) }
            rate = fxRate
        }

        let inBase: Money
        do {
            inBase = try CurrencyConverter.convert(amount, to: baseCurrency, rate: rate)
        } catch {
            return .failure(.fxRateInvalid)
        }

        return .success(Validated(
            kind: kind,
            amount: amount,
            fxRate: rate,
            amountInBase: inBase,
            categoryId: categoryId,
            occurredOn: occurredOn,
            merchant: merchant.isEmpty ? nil : merchant,
            note: note.isEmpty ? nil : note,
            paidBy: paidBy,
            isPrivate: isPrivate
        ))
    }
}
