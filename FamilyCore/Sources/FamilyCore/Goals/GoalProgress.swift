import Foundation

/// Mirrors `public.goal_kind`.
public enum GoalKind: String, Codable, Sendable, CaseIterable {
    case savings, weight, other
}

public struct GoalSpec: Hashable, Sendable {
    public let start: Decimal
    public let target: Decimal
    public let startsOn: LocalDate
    public let deadline: LocalDate?

    public init(start: Decimal, target: Decimal, startsOn: LocalDate, deadline: LocalDate?) {
        self.start = start
        self.target = target
        self.startsOn = startsOn
        self.deadline = deadline
    }
}

public struct GoalReading: Hashable, Sendable {
    public let value: Decimal
    public let on: LocalDate

    public init(value: Decimal, on: LocalDate) {
        self.value = value
        self.on = on
    }
}

public struct GoalStatus: Equatable, Sendable {
    public enum Pace: Equatable, Sendable {
        case achieved
        /// Past the deadline without reaching the target.
        case overdue
        case onTrack
        case behind
        case noDeadline
    }

    public let current: Decimal
    /// 0...1, direction-aware: for a target below the start (weight loss) falling values raise it.
    public let fraction: Double
    public let pace: Pace
    /// Linear extrapolation of the progress so far; nil when there is no usable trend.
    public let projectedFinish: LocalDate?
}

public enum GoalProgress {
    public static func evaluate(_ spec: GoalSpec, readings: [GoalReading], today: LocalDate) -> GoalStatus {
        let latest = readings.max { $0.on < $1.on }
        let current = latest?.value ?? spec.start

        let total = double(spec.target - spec.start)
        let fraction = total == 0 ? 0 : min(1, max(0, double(current - spec.start) / total))

        let pace: GoalStatus.Pace
        if fraction >= 1 {
            pace = .achieved
        } else if let deadline = spec.deadline {
            if today > deadline {
                pace = .overdue
            } else {
                let span = max(1, spec.startsOn.days(until: deadline))
                let elapsed = min(span, max(0, spec.startsOn.days(until: today)))
                pace = fraction >= Double(elapsed) / Double(span) ? .onTrack : .behind
            }
        } else {
            pace = .noDeadline
        }

        return GoalStatus(current: current, fraction: fraction, pace: pace,
                          projectedFinish: fraction >= 1 ? nil : projection(spec, latest: latest, current: current))
    }

    private static func projection(_ spec: GoalSpec, latest: GoalReading?, current: Decimal) -> LocalDate? {
        guard let latest else { return nil }
        let days = spec.startsOn.days(until: latest.on)
        let gained = double(current - spec.start)
        let needed = double(spec.target - spec.start)
        // Needs a positive number of elapsed days and movement towards the target.
        guard days > 0, gained != 0, gained.sign == needed.sign else { return nil }
        let totalDays = (needed / gained) * Double(days)
        guard totalDays.isFinite, totalDays < 365 * 100 else { return nil }
        return spec.startsOn.adding(days: Int(totalDays.rounded(.up)))
    }

    private static func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }
}
