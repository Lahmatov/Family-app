import FamilyCore
import Foundation
import Observation

@MainActor
@Observable
final class TripsModel {
    private(set) var trips: [Trip] = []
    private(set) var items: [TripItem] = []
    private(set) var isLoading = false
    var error: AppError?

    let family: Family
    private let service: any TripServicing
    private let today: () -> LocalDate

    init(family: Family, service: any TripServicing, today: @escaping () -> LocalDate = { LocalDate(Date()) }) {
        self.family = family
        self.service = service
        self.today = today
    }

    func items(for trip: Trip) -> [TripItem] {
        items.filter { $0.tripId == trip.id }
            .sorted { ($0.day ?? .distantFuture, $0.title) < ($1.day ?? .distantFuture, $1.title) }
    }

    func summary(_ trip: Trip) -> TripSummary {
        TripPlanner.summary(budgetMinor: trip.budgetMinor, lines: items(for: trip).map(\.line))
    }

    func countdown(_ trip: Trip) -> TripCountdown {
        TripPlanner.countdown(starts: trip.startsOn, ends: trip.endsOn, today: today())
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await perform {
            async let t = service.trips(familyId: family.id)
            async let i = service.items(familyId: family.id)
            (trips, items) = try await (t, i)
        }
    }

    func add(_ trip: NewTrip) async throws {
        try await service.add(familyId: family.id, trip)
        await load()
    }

    func add(_ item: NewTripItem, to trip: Trip) async throws {
        try await service.add(familyId: family.id, tripId: trip.id, item)
        await load()
    }

    func setDone(_ item: TripItem, done: Bool) async {
        await perform {
            try await service.setDone(item, done: done)
            if let index = items.firstIndex(of: item) { items[index].isDone = done }
        }
    }

    func delete(_ trip: Trip) async {
        await perform {
            try await service.delete(trip)
            trips.removeAll { $0.id == trip.id }
            items.removeAll { $0.tripId == trip.id }
        }
    }

    func delete(_ item: TripItem) async {
        await perform {
            try await service.delete(item)
            items.removeAll { $0.id == item.id }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch let appError as AppError { error = appError } catch { self.error = .unknown }
    }
}

private extension LocalDate {
    static let distantFuture = LocalDate(year: 2100, month: 1, day: 1)!
}
