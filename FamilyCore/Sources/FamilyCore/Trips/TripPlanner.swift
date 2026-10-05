import Foundation

/// Mirrors `public.trip_item_kind`.
public enum TripItemKind: String, Codable, Sendable, CaseIterable {
    case transport, stay, activity, todo
}

/// The part of a trip item the planner needs.
public struct TripLine: Hashable, Sendable {
    public let kind: TripItemKind
    public let day: LocalDate?
    public let costMinor: Int64
    public let isDone: Bool

    public init(kind: TripItemKind, day: LocalDate?, costMinor: Int64, isDone: Bool) {
        self.kind = kind
        self.day = day
        self.costMinor = costMinor
        self.isDone = isDone
    }
}

public struct TripSummary: Equatable, Sendable {
    /// Everything on the list, booked or not.
    public let plannedMinor: Int64
    /// Items ticked off (booked / paid).
    public let doneMinor: Int64
    /// Budget minus planned; negative when over budget.
    public let remainingMinor: Int64
    public let overBudget: Bool
    public let doneCount: Int
    public let totalCount: Int
    /// Cost of items that have no day yet.
    public let undatedMinor: Int64
}

public enum TripCountdown: Equatable, Sendable {
    case upcoming(days: Int)
    /// 1-based day of the trip.
    case ongoing(day: Int, of: Int)
    case finished
}

public enum TripPlanner {
    public static func summary(budgetMinor: Int64, lines: [TripLine]) -> TripSummary {
        let planned = lines.reduce(Int64(0)) { $0 + $1.costMinor }
        return TripSummary(
            plannedMinor: planned,
            doneMinor: lines.filter(\.isDone).reduce(Int64(0)) { $0 + $1.costMinor },
            remainingMinor: budgetMinor - planned,
            overBudget: planned > budgetMinor,
            doneCount: lines.filter(\.isDone).count,
            totalCount: lines.count,
            undatedMinor: lines.filter { $0.day == nil }.reduce(Int64(0)) { $0 + $1.costMinor })
    }

    public static func countdown(starts: LocalDate, ends: LocalDate, today: LocalDate) -> TripCountdown {
        if today < starts { return .upcoming(days: today.days(until: starts)) }
        if today > ends { return .finished }
        return .ongoing(day: starts.days(until: today) + 1, of: starts.days(until: ends) + 1)
    }
}
