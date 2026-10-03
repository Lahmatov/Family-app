import Foundation

/// Mirrors `public.sport_entry_kind`.
public enum SportKind: String, Codable, Sendable, CaseIterable {
    /// Repeats every week on `weekday`, optionally until a date.
    case training
    /// One-off: a match, competition, tournament.
    case event
}

public struct SportEntry: Hashable, Sendable {
    public let id: UUID
    public let kind: SportKind
    /// ISO weekday (Monday = 1) for trainings.
    public let weekday: Int?
    /// Date of an event.
    public let onDate: LocalDate?
    /// Minutes after midnight.
    public let startMinute: Int
    public let durationMinutes: Int
    /// Last day of a recurring training (season end).
    public let until: LocalDate?

    public init(id: UUID, kind: SportKind, weekday: Int?, onDate: LocalDate?, startMinute: Int, durationMinutes: Int, until: LocalDate?) {
        self.id = id
        self.kind = kind
        self.weekday = weekday
        self.onDate = onDate
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.until = until
    }
}

public struct SportOccurrence: Hashable, Sendable {
    public let entryId: UUID
    public let date: LocalDate
    public let startMinute: Int
    public let endMinute: Int
}

public enum SportsCalendar {
    /// Longest window expanded at once (a year), so a bad range cannot loop for long.
    public static let maxDays = 366

    /// Every training and event that falls in `from...through`, ordered by day, start time, then id.
    public static func occurrences(of entries: [SportEntry], from: LocalDate, through: LocalDate) -> [SportOccurrence] {
        guard through >= from else { return [] }
        let last = min(through, from.adding(days: maxDays - 1))
        var result: [SportOccurrence] = []
        for entry in entries {
            let end = entry.startMinute + entry.durationMinutes
            switch entry.kind {
            case .event:
                if let day = entry.onDate, day >= from, day <= last {
                    result.append(SportOccurrence(entryId: entry.id, date: day, startMinute: entry.startMinute, endMinute: end))
                }
            case .training:
                guard let weekday = entry.weekday else { continue }
                let stop = min(last, entry.until ?? last)
                guard stop >= from else { continue }
                // First matching weekday on or after `from`, then every 7 days.
                var day = from.adding(days: (weekday - from.isoWeekday + 7) % 7)
                while day <= stop {
                    result.append(SportOccurrence(entryId: entry.id, date: day, startMinute: entry.startMinute, endMinute: end))
                    day = day.adding(days: 7)
                }
            }
        }
        return result.sorted {
            ($0.date, $0.startMinute, $0.entryId.uuidString) < ($1.date, $1.startMinute, $1.entryId.uuidString)
        }
    }

    /// Pairs that overlap in time on the same day (two children, or one child double-booked).
    /// Back-to-back sessions (one ends when the next starts) do not clash.
    public static func clashes(_ occurrences: [SportOccurrence]) -> [(SportOccurrence, SportOccurrence)] {
        var pairs: [(SportOccurrence, SportOccurrence)] = []
        let byDay = Dictionary(grouping: occurrences, by: \.date)
        for day in byDay.keys.sorted() {
            let sorted = byDay[day]!.sorted { $0.startMinute < $1.startMinute }
            for (index, first) in sorted.enumerated() {
                for second in sorted[(index + 1)...] {
                    if second.startMinute >= first.endMinute { break }
                    pairs.append((first, second))
                }
            }
        }
        return pairs
    }
}
