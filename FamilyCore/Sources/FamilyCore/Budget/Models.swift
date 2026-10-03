import Foundation

/// Mirrors `public.txn_kind`.
public enum TransactionKind: String, Codable, Sendable, CaseIterable {
    case expense
    case income
}

/// Row of `public.families`.
public struct Family: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public let baseCurrency: CurrencyCode

    public init(id: UUID, name: String, baseCurrency: CurrencyCode) {
        self.id = id
        self.name = name
        self.baseCurrency = baseCurrency
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case baseCurrency = "base_currency"
    }
}

/// Row of `public.family_members`.
public struct FamilyMember: Codable, Hashable, Sendable {
    public let familyId: UUID
    public let userId: UUID
    public let role: MemberRole

    public init(familyId: UUID, userId: UUID, role: MemberRole) {
        self.familyId = familyId
        self.userId = userId
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case familyId = "family_id"
        case userId = "user_id"
        case role
    }
}

/// Row of `public.categories`.
public struct Category: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let familyId: UUID
    public let kind: TransactionKind
    /// Built-in categories have a key that the app localises (see `localizationKey`).
    public let systemKey: String?
    public var name: String?
    public var icon: String?
    public var color: String?
    public var sortOrder: Int
    public var archived: Bool

    public init(id: UUID, familyId: UUID, kind: TransactionKind, systemKey: String?, name: String?,
                icon: String?, color: String?, sortOrder: Int, archived: Bool) {
        self.id = id
        self.familyId = familyId
        self.kind = kind
        self.systemKey = systemKey
        self.name = name
        self.icon = icon
        self.color = color
        self.sortOrder = sortOrder
        self.archived = archived
    }

    /// Key for the string catalog, e.g. "category.groceries".
    public var localizationKey: String? { systemKey.map { "category.\($0)" } }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, icon, color, archived
        case familyId = "family_id"
        case systemKey = "system_key"
        case sortOrder = "sort_order"
    }
}

/// Row of `public.transactions`.
public struct Transaction: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let familyId: UUID
    public var kind: TransactionKind
    public var amountMinor: Int64
    public var currency: CurrencyCode
    public var fxRate: Decimal
    public let amountBaseMinor: Int64
    public var categoryId: UUID
    public var occurredOn: LocalDate
    public var merchant: String?
    public var note: String?
    public var paidBy: UUID?
    public var isPrivate: Bool
    public let createdBy: UUID?

    public init(id: UUID, familyId: UUID, kind: TransactionKind, amountMinor: Int64, currency: CurrencyCode,
                fxRate: Decimal, amountBaseMinor: Int64, categoryId: UUID, occurredOn: LocalDate,
                merchant: String?, note: String?, paidBy: UUID?, isPrivate: Bool, createdBy: UUID?) {
        self.id = id
        self.familyId = familyId
        self.kind = kind
        self.amountMinor = amountMinor
        self.currency = currency
        self.fxRate = fxRate
        self.amountBaseMinor = amountBaseMinor
        self.categoryId = categoryId
        self.occurredOn = occurredOn
        self.merchant = merchant
        self.note = note
        self.paidBy = paidBy
        self.isPrivate = isPrivate
        self.createdBy = createdBy
    }

    public var amount: Money { Money(minorUnits: amountMinor, currency: currency) }

    enum CodingKeys: String, CodingKey {
        case id, kind, currency, merchant, note
        case familyId = "family_id"
        case amountMinor = "amount_minor"
        case fxRate = "fx_rate"
        case amountBaseMinor = "amount_base_minor"
        case categoryId = "category_id"
        case occurredOn = "occurred_on"
        case paidBy = "paid_by"
        case isPrivate = "is_private"
        case createdBy = "created_by"
    }
}

/// Row of `public.budgets`. `categoryId == nil` is the overall monthly budget.
public struct Budget: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let familyId: UUID
    public let categoryId: UUID?
    public var amountMinor: Int64
    public let validFrom: LocalDate

    public init(id: UUID, familyId: UUID, categoryId: UUID?, amountMinor: Int64, validFrom: LocalDate) {
        self.id = id
        self.familyId = familyId
        self.categoryId = categoryId
        self.amountMinor = amountMinor
        self.validFrom = validFrom
    }

    enum CodingKeys: String, CodingKey {
        case id
        case familyId = "family_id"
        case categoryId = "category_id"
        case amountMinor = "amount_minor"
        case validFrom = "valid_from"
    }
}
