import Foundation

/// One scheduled dose.
public struct ScheduledDose: Hashable, Sendable {
    public let vaccine: String // matches `child_vaccinations.vaccine_code`
    public let dose: Int
    /// Recommended age in months at which the dose is due.
    public let ageMonths: Int
}

public enum VaccinationSchedule {
    /// DRAFT of Portugal's national programme (PNV), written from memory.
    /// It MUST be checked against the current DGS norm before anyone relies on it, and the app
    /// shows a "check with your paediatrician" notice next to it. Edit the table, not the logic.
    public static let portugalDraft: [ScheduledDose] = [
        .init(vaccine: "hepb", dose: 1, ageMonths: 0),
        .init(vaccine: "hexa", dose: 1, ageMonths: 2), .init(vaccine: "pcv13", dose: 1, ageMonths: 2),
        .init(vaccine: "menb", dose: 1, ageMonths: 2),
        .init(vaccine: "hexa", dose: 2, ageMonths: 4), .init(vaccine: "pcv13", dose: 2, ageMonths: 4),
        .init(vaccine: "menb", dose: 2, ageMonths: 4),
        .init(vaccine: "hexa", dose: 3, ageMonths: 6),
        .init(vaccine: "mmr", dose: 1, ageMonths: 12), .init(vaccine: "pcv13", dose: 3, ageMonths: 12),
        .init(vaccine: "menb", dose: 3, ageMonths: 12), .init(vaccine: "menc", dose: 1, ageMonths: 12),
        .init(vaccine: "hexa", dose: 4, ageMonths: 18),
        .init(vaccine: "dtpa_ipv", dose: 5, ageMonths: 60), .init(vaccine: "mmr", dose: 2, ageMonths: 60),
        .init(vaccine: "hpv", dose: 1, ageMonths: 120), .init(vaccine: "hpv", dose: 2, ageMonths: 126),
        .init(vaccine: "td", dose: 6, ageMonths: 120),
    ]
}

public struct GivenDose: Hashable, Sendable {
    public let vaccine: String
    public let dose: Int
    public let givenOn: LocalDate

    public init(vaccine: String, dose: Int, givenOn: LocalDate) {
        self.vaccine = vaccine
        self.dose = dose
        self.givenOn = givenOn
    }
}

public struct VaccinationItem: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case done(on: LocalDate)
        case overdue(days: Int)
        /// Due within the next `soonWindowDays`.
        case dueSoon(inDays: Int)
        case upcoming(inDays: Int)
    }

    public let scheduled: ScheduledDose
    public let dueDate: LocalDate
    public let state: State
}

public enum VaccinationPlanner {
    public static let soonWindowDays = 30

    /// Plan for one child, ordered by due date. Doses not in the schedule (extra vaccines)
    /// are ignored here; they remain visible in the raw record list.
    public static func plan(
        birth: LocalDate, given: [GivenDose], today: LocalDate,
        schedule: [ScheduledDose] = VaccinationSchedule.portugalDraft
    ) -> [VaccinationItem] {
        let doneOn = Dictionary(given.map { ("\($0.vaccine)#\($0.dose)", $0.givenOn) }, uniquingKeysWith: min)
        return schedule.compactMap { dose -> VaccinationItem? in
            guard let due = birth.adding(months: dose.ageMonths) else { return nil }
            let state: VaccinationItem.State
            if let date = doneOn["\(dose.vaccine)#\(dose.dose)"] {
                state = .done(on: date)
            } else {
                let delta = today.days(until: due)
                state = delta < 0 ? .overdue(days: -delta)
                    : delta <= soonWindowDays ? .dueSoon(inDays: delta) : .upcoming(inDays: delta)
            }
            return VaccinationItem(scheduled: dose, dueDate: due, state: state)
        }
        .sorted { ($0.dueDate, $0.scheduled.vaccine, $0.scheduled.dose) < ($1.dueDate, $1.scheduled.vaccine, $1.scheduled.dose) }
    }

    /// The next dose that needs attention: the most overdue one, else the nearest upcoming.
    public static func nextAction(_ items: [VaccinationItem]) -> VaccinationItem? {
        items.first { if case .overdue = $0.state { true } else { false } }
            ?? items.first { if case .dueSoon = $0.state { true } else { false } }
            ?? items.first { if case .upcoming = $0.state { true } else { false } }
    }
}
