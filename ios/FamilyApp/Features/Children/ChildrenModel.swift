import FamilyCore
import Foundation
import Observation

@MainActor
@Observable
final class ChildrenModel {
    private(set) var children: [Child] = []
    private(set) var isLoading = false
    var error: AppError?

    let family: Family
    let role: MemberRole
    let service: any ChildServicing
    private let today: () -> LocalDate

    init(family: Family, role: MemberRole, service: any ChildServicing,
         today: @escaping () -> LocalDate = { LocalDate(Date()) }) {
        self.family = family
        self.role = role
        self.service = service
        self.today = today
    }

    var canDelete: Bool { role == .admin }

    func age(_ child: Child) -> Age? { Age(birth: child.birthDate, on: today()) }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await perform { children = try await service.children(familyId: family.id) }
    }

    func add(name: String, birthDate: LocalDate, sex: ChildSex, bloodType: String?, allergies: String?) async throws {
        try await service.add(familyId: family.id, name: name, birthDate: birthDate, sex: sex,
                              bloodType: bloodType, allergies: allergies)
        await load()
    }

    func delete(_ child: Child) async {
        await perform {
            try await service.delete(child)
            children.removeAll { $0.id == child.id }
        }
    }

    func detail(for child: Child) -> ChildDetailModel {
        ChildDetailModel(child: child, familyId: family.id, service: service, today: today)
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch let appError as AppError { error = appError } catch { self.error = .unknown }
    }
}

@MainActor
@Observable
final class ChildDetailModel {
    private(set) var vaccinations: [ChildVaccination] = []
    private(set) var measurements: [Measurement] = []
    private(set) var illnesses: [Illness] = []
    var error: AppError?

    let child: Child
    private let familyId: UUID
    private let service: any ChildServicing
    private let today: () -> LocalDate

    init(child: Child, familyId: UUID, service: any ChildServicing, today: @escaping () -> LocalDate) {
        self.child = child
        self.familyId = familyId
        self.service = service
        self.today = today
    }

    var plan: [VaccinationItem] {
        VaccinationPlanner.plan(
            birth: child.birthDate,
            given: vaccinations.map { GivenDose(vaccine: $0.vaccineCode, dose: $0.dose, givenOn: $0.givenOn) },
            today: today())
    }

    var nextVaccination: VaccinationItem? { VaccinationPlanner.nextAction(plan) }

    func load() async {
        await perform {
            async let v = service.vaccinations(childId: child.id)
            async let m = service.measurements(childId: child.id)
            async let i = service.illnesses(childId: child.id)
            (vaccinations, measurements, illnesses) = try await (v, m, i)
        }
    }

    func markGiven(_ dose: ScheduledDose, on day: LocalDate) async {
        await perform {
            try await service.record(familyId: familyId, childId: child.id, vaccine: dose.vaccine, dose: dose.dose, on: day)
            await load()
        }
    }

    func measure(on day: LocalDate, heightMm: Int?, weightG: Int?) async throws {
        try await service.measure(familyId: familyId, childId: child.id, on: day, heightMm: heightMm, weightG: weightG)
        await load()
    }

    func addIllness(title: String, startedOn: LocalDate) async throws {
        try await service.addIllness(familyId: familyId, childId: child.id, title: title, startedOn: startedOn)
        await load()
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch let appError as AppError { error = appError } catch { self.error = .unknown }
    }
}
