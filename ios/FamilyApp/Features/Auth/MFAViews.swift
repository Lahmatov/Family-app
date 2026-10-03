import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// First-time setup of the second factor (TOTP). Required before any family data is reachable.
struct MFAEnrollView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var enrollment: TOTPEnrollment?
    @State private var code = ""
    @State private var showSecret = false
    @State private var action = AsyncAction()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("mfa.enroll.explanation")
                }
                if let enrollment {
                    Section("mfa.enroll.step1") {
                        if let image = QRCode.image(for: enrollment.uri) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(Text("mfa.enroll.qr"))
                        }
                        if let url = URL(string: enrollment.uri) {
                            Button {
                                openURL(url)
                            } label: {
                                Label("mfa.enroll.addToPasswords", systemImage: "key.viewfinder")
                            }
                        }
                        DisclosureGroup("mfa.enroll.manual", isExpanded: $showSecret) {
                            Text(enrollment.secret)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .privacySensitive()
                        }
                    }
                    Section("mfa.enroll.step2") {
                        CodeField(code: $code)
                        Button("mfa.verify") {
                            Task {
                                await action.run {
                                    try await model.services.auth.verifyTOTP(factorId: enrollment.factorId, code: code)
                                    code = ""
                                    await model.refresh()
                                }
                            }
                        }
                        .disabled(code.count != 6 || action.isRunning)
                        .accessibilityIdentifier("verifyCodeButton")
                    }
                } else {
                    ProgressView()
                }
                Section {
                    Button("settings.signOut", role: .destructive) { Task { await model.signOut() } }
                }
            }
            .navigationTitle("mfa.enroll.title")
            .errorAlert(action)
            .task {
                guard enrollment == nil else { return }
                await action.run { enrollment = try await model.services.auth.enrollTOTP() }
            }
        }
    }
}

struct MFAChallengeView: View {
    @Environment(AppModel.self) private var model
    let factorId: String
    @State private var code = ""
    @State private var action = AsyncAction()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CodeField(code: $code)
                } footer: {
                    Text("mfa.challenge.footer")
                }
                Section {
                    Button {
                        Task {
                            await action.run {
                                try await model.services.auth.verifyTOTP(factorId: factorId, code: code)
                                code = ""
                                await model.refresh()
                            }
                        }
                    } label: {
                        if action.isRunning { ProgressView() } else { Text("mfa.verify") }
                    }
                    .disabled(code.count != 6 || action.isRunning)
                    .accessibilityIdentifier("verifyCodeButton")
                    Button("settings.signOut", role: .destructive) { Task { await model.signOut() } }
                }
            }
            .navigationTitle("mfa.challenge.title")
            .errorAlert(action)
        }
    }
}

/// 6-digit one-time code input with iOS autofill from Passwords.
struct CodeField: View {
    @Binding var code: String

    var body: some View {
        TextField("mfa.code", text: $code)
            .textContentType(.oneTimeCode)
            .keyboardType(.numberPad)
            .font(.title2.monospacedDigit())
            .multilineTextAlignment(.center)
            .onChange(of: code) { _, newValue in
                let digits = String(newValue.filter(\.isASCII).filter(\.isNumber).prefix(6))
                if digits != newValue { code = digits }
            }
            .accessibilityIdentifier("codeField")
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
