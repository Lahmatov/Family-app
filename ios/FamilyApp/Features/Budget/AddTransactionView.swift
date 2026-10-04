import FamilyCore
import PhotosUI
import SwiftUI
import UIKit

struct AddTransactionView: View {
    let model: BudgetModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var draft: TransactionDraft
    @State private var date = Date()
    @State private var rateText = ""
    /// The rate shown came from the ECB, not from the person; it is replaced when the currency or date changes.
    @State private var suggested: ReferenceRate?
    @State private var photoItem: PhotosPickerItem?
    @State private var receipt: ReceiptUpload?
    @State private var action = AsyncAction()
    @State private var validationError: TransactionDraft.ValidationError?

    init(model: BudgetModel) {
        self.model = model
        _draft = State(initialValue: TransactionDraft(currency: model.family.baseCurrency, occurredOn: LocalDate(Date())))
    }

    private var categories: [FamilyCore.Category] {
        model.categories.filter { $0.kind == draft.kind }
    }

    private var preview: TransactionDraft.Validated? {
        var input = draft
        input.fxRate = Decimal(string: rateText.replacingOccurrences(of: ",", with: "."))
        input.occurredOn = LocalDate(date)
        return try? input.validate(baseCurrency: model.family.baseCurrency).get()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("budget.kind", selection: $draft.kind) {
                        Text("budget.expense").tag(TransactionKind.expense)
                        Text("budget.incomeKind").tag(TransactionKind.income)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draft.kind) { _, _ in draft.categoryId = nil }

                    HStack {
                        TextField("budget.amount", text: $draft.amountText)
                            .keyboardType(.decimalPad)
                            .font(.title2.monospacedDigit())
                            .accessibilityIdentifier("amountField")
                        Picker("", selection: $draft.currency) {
                            ForEach(currencyOptions, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                    }
                    if draft.currency != model.family.baseCurrency {
                        TextField("budget.rate \(model.family.baseCurrency.rawValue) \(draft.currency.rawValue)",
                                  text: $rateText)
                            .keyboardType(.decimalPad)
                            .onChange(of: rateText) { _, text in if text != suggested.map({ "\($0.rate)" }) { suggested = nil } }
                        if let suggested {
                            Text("budget.rate.ecb \(suggested.publishedOn.formatted(locale: locale))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let preview {
                            Text("budget.inBase \(preview.amountInBase.formatted(locale: locale))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("budget.category") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 8) {
                        ForEach(categories) { category in
                            Button {
                                draft.categoryId = category.id
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: category.icon ?? "circle")
                                        .font(.title3)
                                    Text(category.displayName).font(.caption).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .background(draft.categoryId == category.id ? Color.accentColor.opacity(0.2) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("category-\(category.systemKey ?? category.id.uuidString)")
                        }
                    }
                }

                Section {
                    DatePicker("budget.date", selection: $date, in: ...Date(), displayedComponents: .date)
                    TextField("budget.merchant", text: $draft.merchant)
                    TextField("budget.note", text: $draft.note, axis: .vertical)
                    Toggle("budget.privateToggle", isOn: $draft.isPrivate)
                } footer: {
                    if draft.isPrivate { Text("budget.private.footer") }
                }

                Section("budget.receipt") {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(receipt == nil ? LocalizedStringKey("budget.receipt.add") : LocalizedStringKey("budget.receipt.replace"),
                              systemImage: "doc.text.viewfinder")
                    }
                    if receipt != nil {
                        Label("budget.receipt.attached", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("budget.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save() }
                        .disabled(action.isRunning)
                        .accessibilityIdentifier("saveTransactionButton")
                }
            }
            .onChange(of: photoItem) { _, item in
                Task { receipt = await ReceiptProcessor.load(item) }
            }
            .alert("error.title", isPresented: Binding(get: { validationError != nil },
                                                       set: { if !$0 { validationError = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(validationError?.messageKey ?? "")
            }
            .errorAlert(action)
            .task(id: "\(draft.currency)-\(LocalDate(date))") { await suggestRate() }
        }
    }

    /// Prefills the ECB rate unless the person typed their own.
    private func suggestRate() async {
        let base = model.family.baseCurrency
        guard draft.currency != base, rateText.isEmpty || suggested != nil else { return }
        let rate = await ExchangeRateClient.referenceRate(from: draft.currency, to: base, on: LocalDate(date))
        guard !Task.isCancelled, rateText.isEmpty || suggested != nil else { return }
        suggested = rate
        rateText = rate.map { "\($0.rate)" } ?? ""
    }

    private var currencyOptions: [CurrencyCode] {
        var options = CurrencyCode.common
        if !options.contains(model.family.baseCurrency) { options.insert(model.family.baseCurrency, at: 0) }
        return options
    }

    private func save() {
        var input = draft
        input.fxRate = Decimal(string: rateText.replacingOccurrences(of: ",", with: "."))
        input.occurredOn = LocalDate(date)
        input.paidBy = app.userId
        switch input.validate(baseCurrency: model.family.baseCurrency) {
        case let .failure(error):
            validationError = error
        case let .success(validated):
            Task {
                await action.run {
                    try await model.add(validated, receipt: receipt)
                    dismiss()
                }
            }
        }
    }
}

extension TransactionDraft.ValidationError {
    var messageKey: LocalizedStringKey {
        switch self {
        case .amountMissing: "validation.amountMissing"
        case .amountInvalid: "validation.amountInvalid"
        case .amountNotPositive: "validation.amountNotPositive"
        case .amountTooLarge: "validation.amountTooLarge"
        case .categoryMissing: "validation.categoryMissing"
        case .fxRateMissing: "validation.fxRateMissing"
        case .fxRateInvalid: "validation.fxRateInvalid"
        case .merchantTooLong, .noteTooLong: "validation.tooLong"
        case .dateOutOfRange: "validation.date"
        }
    }
}

/// Converts a picked photo into a compact JPEG. Re-encoding strips EXIF metadata,
/// including GPS location, before anything leaves the device.
enum ReceiptProcessor {
    static let maxDimension: CGFloat = 2000
    static let maxBytes = 20 * 1024 * 1024

    static func load(_ item: PhotosPickerItem?) async -> ReceiptUpload? {
        guard let item, let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return nil }
        return process(image)
    }

    static func process(_ image: UIImage) -> ReceiptUpload? {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.7), jpeg.count <= maxBytes else { return nil }
        return ReceiptUpload(data: jpeg, mimeType: "image/jpeg", fileExtension: "jpg")
    }
}
