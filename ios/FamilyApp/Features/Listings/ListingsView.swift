import CoreLocation
import FamilyCore
import MapKit
import SwiftUI
import UIKit

struct ListingsHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let membership = app.currentMembership, membership.role.isAtLeast(.adult) {
            ListingsContentView(model: ListingsModel(family: membership.family, service: app.services.listings))
                .id(membership.id)
        } else {
            ContentUnavailableView("listings.noAccess", systemImage: "lock")
        }
    }
}

private struct ListingsContentView: View {
    @State var model: ListingsModel
    @State private var showAdd = false
    @State private var showCriteria = false
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            List {
                if model.ranked.isEmpty && !model.isLoading {
                    ContentUnavailableView("listings.empty", systemImage: "house",
                                           description: Text("listings.empty.description"))
                }
                ForEach(Array(model.ranked.enumerated()), id: \.element.listing.id) { index, item in
                    NavigationLink(value: item.listing.id) {
                        ListingRow(listing: item.listing, rank: item.rank, position: index + 1, locale: locale)
                    }
                }
                if !model.rejected.isEmpty {
                    Section("listings.rejected") {
                        ForEach(model.rejected) { listing in
                            Text(listing.title.isEmpty ? listing.source ?? "" : listing.title).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("tab.listings")
            .navigationDestination(for: UUID.self) { id in
                if let listing = model.listings.first(where: { $0.id == id }) {
                    ListingDetailView(model: model, listing: listing)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showCriteria = true } label: { Image(systemName: "checklist") }
                        .accessibilityLabel(Text("listings.criteria"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
                        .accessibilityLabel(Text("listings.add"))
                        .accessibilityIdentifier("addListingButton")
                }
            }
            .sheet(isPresented: $showAdd) { AddListingView(model: model) }
            .sheet(isPresented: $showCriteria) { CriteriaView(model: model) }
            .refreshable { await model.load() }
            .task { await model.load() }
            .alert("error.title", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(model.error?.localizedDescription ?? "")
            }
        }
    }
}

private struct ListingRow: View {
    let listing: Listing
    let rank: RankedListing
    let position: Int
    let locale: Locale

    var body: some View {
        HStack(spacing: 12) {
            Text("\(position)").font(.title3.bold()).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(listing.title.isEmpty ? listing.source ?? "" : listing.title).font(.headline).lineLimit(2)
                HStack(spacing: 8) {
                    if let price = listing.priceMinor {
                        Text(Money(minorUnits: price, currency: listing.currency).formatted(locale: locale))
                    }
                    if let area = rank.listing.pricePerM2Minor {
                        Text("listings.perM2 \(Money(minorUnits: area, currency: listing.currency).formatted(locale: locale))")
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                Text(listing.status.titleKey).font(.caption).foregroundStyle(listing.status.color)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("\(rank.score)%").font(.title3.monospacedDigit().bold())
                if rank.unanswered > 0 {
                    Text("listings.unanswered \(rank.unanswered)").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }
}

struct ListingDetailView: View {
    let model: ListingsModel
    let listing: Listing
    @State private var comments: [ListingComment] = []
    @State private var newComment = ""
    @State private var action = AsyncAction()
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            Section {
                Button { openURL(listing.url) } label: {
                    Label(listing.source ?? listing.url.host() ?? "", systemImage: "safari")
                }
                Picker("listings.status", selection: Binding(
                    get: { listing.status }, set: { status in Task { await model.setStatus(listing, status) } })) {
                    ForEach(ListingStatus.allCases, id: \.self) { Text($0.titleKey).tag($0) }
                }
                if let address = listing.address { Label(address, systemImage: "mappin.and.ellipse") }
                if let rooms = listing.rooms { LabeledContent("listings.rooms", value: "T\(rooms)") }
                if let area = listing.areaM2 { LabeledContent("listings.area", value: "\(area) m²") }
            }
            if let lat = listing.lat, let lng = listing.lng {
                Section {
                    let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                    Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500,
                                                                    longitudinalMeters: 1500))) {
                        Marker(listing.title, coordinate: coordinate)
                    }
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                }
            }
            Section("listings.checklist") {
                if model.criteria.isEmpty { Text("listings.checklist.empty").foregroundStyle(.secondary) }
                ForEach(model.criteria) { criterion in
                    HStack {
                        Text(criterion.name)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.answer(listing, criterion) },
                            set: { answer in Task { await model.setAnswer(listing, criterion, answer) } })) {
                            Text("listings.yes").tag(CriterionAnswer.yes)
                            Text("listings.no").tag(CriterionAnswer.no)
                            Text("listings.unknown").tag(CriterionAnswer.unknown)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 190)
                    }
                }
            }
            Section("listings.comments") {
                ForEach(comments) { comment in
                    VStack(alignment: .leading) {
                        Text(comment.body)
                        Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("listings.comment.placeholder", text: $newComment, axis: .vertical)
                    Button {
                        let body = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await action.run {
                                try await model.addComment(listing, body: body)
                                newComment = ""
                                comments = await model.comments(listing)
                            }
                        }
                    } label: { Image(systemName: "paperplane.fill") }
                    .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || action.isRunning)
                    .accessibilityLabel(Text("listings.comment.send"))
                }
            }
            Section {
                Button("listings.delete", role: .destructive) { Task { await model.delete(listing) } }
            }
        }
        .navigationTitle(listing.title.isEmpty ? listing.source ?? "" : listing.title)
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert(action)
        .task { comments = await model.comments(listing) }
    }
}

private struct ImportTarget: Identifiable {
    let url: URL
    var id: URL { url }
}

struct AddListingView: View {
    let model: ListingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var title = ""
    @State private var price = ""
    @State private var area = ""
    @State private var rooms = ""
    @State private var address = ""
    @State private var action = AsyncAction()
    @State private var invalid: LocalizedStringKey?
    @State private var importTarget: ImportTarget?
    @State private var imported = false
    /// Exact coordinates from the page; used only while the address is the one the page gave.
    @State private var importedPlace: (address: String, lat: Double, lng: Double)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("listings.link", text: $link)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("listingLinkField")
                    Button("listings.paste") { if let text = UIPasteboard.general.string { link = text } }
                    Button("listings.import") { importTarget = (try? ListingLink(parsing: link)).map { ImportTarget(url: $0.url) } }
                        .disabled((try? ListingLink(parsing: link)) == nil)
                        .accessibilityIdentifier("importListingButton")
                } footer: { Text("listings.link.footer") }
                Section {
                    TextField("listings.title", text: $title)
                    TextField("listings.price", text: $price).keyboardType(.decimalPad)
                    TextField("listings.area", text: $area).keyboardType(.decimalPad)
                    TextField("listings.rooms", text: $rooms).keyboardType(.numberPad)
                    TextField("listings.address", text: $address)
                } footer: {
                    VStack(alignment: .leading) {
                        if imported { Text("listings.import.check").foregroundStyle(.orange) }
                        Text("listings.address.footer")
                    }
                }
                if let invalid { Section { Text(invalid).foregroundStyle(.red) } }
            }
            .navigationTitle("listings.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save() }.disabled(link.isEmpty || action.isRunning)
                        .accessibilityIdentifier("saveListingButton")
                }
            }
            .errorAlert(action)
            .sheet(item: $importTarget) { target in
                ListingImportView(url: target.url) { apply($0) }
            }
        }
    }

    private func apply(_ draft: ListingDraft) {
        imported = true
        if title.isEmpty { title = draft.title }
        if let minor = draft.priceMinor {
            price = minor % 100 == 0 ? String(minor / 100) : String(format: "%lld.%02lld", minor / 100, minor % 100)
        }
        if let area = draft.areaM2 { self.area = "\(area)" }
        if let rooms = draft.rooms { self.rooms = String(rooms) }
        if let found = draft.address { address = found }
        if let lat = draft.latitude, let lng = draft.longitude { importedPlace = (address, lat, lng) }
    }

    private func save() {
        guard let parsed = try? ListingLink(parsing: link) else { invalid = "listings.link.invalid"; return }
        let base = model.family.baseCurrency
        var new = NewListing(link: parsed)
        new.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !price.isEmpty {
            guard let money = try? Money(parsing: price, currency: base), money.minorUnits > 0 else {
                invalid = "validation.amountInvalid"; return
            }
            new.priceMinor = money.minorUnits
        }
        if !area.isEmpty {
            guard let value = Decimal(string: area.replacingOccurrences(of: ",", with: ".")), value > 0 else {
                invalid = "listings.area.invalid"; return
            }
            new.areaM2 = value
        }
        new.rooms = Int(rooms)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        new.address = trimmedAddress.isEmpty ? nil : trimmedAddress
        invalid = nil
        Task {
            await action.run {
                if let known = importedPlace, known.address == new.address {
                    new.lat = known.lat
                    new.lng = known.lng
                } else if let address = new.address,
                          let place = try? await CLGeocoder().geocodeAddressString(address).first?.location?.coordinate {
                    new.lat = place.latitude
                    new.lng = place.longitude
                }
                try await model.add(new)
                dismiss()
            }
        }
    }
}

struct CriteriaView: View {
    let model: ListingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var weight = 3

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.criteria) { criterion in
                        LabeledContent(criterion.name, value: String(repeating: "★", count: criterion.weight))
                    }
                } footer: { Text("listings.criteria.footer") }
                Section("listings.criteria.new") {
                    TextField("listings.criteria.name", text: $name)
                    Stepper("listings.criteria.weight \(weight)", value: $weight, in: 1...5)
                    Button("listings.criteria.add") {
                        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await model.addCriterion(name: value, weight: weight); name = "" }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("listings.criteria")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } } }
        }
    }
}

extension ListingStatus {
    var titleKey: LocalizedStringKey {
        switch self {
        case .new: "listings.status.new"
        case .toVisit: "listings.status.toVisit"
        case .visited: "listings.status.visited"
        case .shortlisted: "listings.status.shortlisted"
        case .rejected: "listings.status.rejected"
        }
    }

    var color: Color {
        switch self {
        case .new: .secondary
        case .toVisit: .blue
        case .visited: .purple
        case .shortlisted: .green
        case .rejected: .red
        }
    }
}
