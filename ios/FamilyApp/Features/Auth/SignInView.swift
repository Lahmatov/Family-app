import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var action = AsyncAction()
    @State private var showSignUp = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("auth.email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("emailField")
                    SecureField("auth.password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("passwordField")
                } footer: {
                    Text("auth.signIn.footer")
                }

                Section {
                    Button {
                        Task {
                            await action.run {
                                try await model.services.auth.signIn(
                                    email: email.trimmingCharacters(in: .whitespaces), password: password)
                                password = ""
                                await model.refresh()
                            }
                        }
                    } label: {
                        if action.isRunning { ProgressView() } else { Text("auth.signIn") }
                    }
                    .disabled(email.isEmpty || password.isEmpty || action.isRunning)
                    .accessibilityIdentifier("signInButton")

                    Button("auth.createAccount") { showSignUp = true }
                        .accessibilityIdentifier("createAccountButton")
                }
            }
            .navigationTitle("app.name")
            .errorAlert(action)
            .sheet(isPresented: $showSignUp) { SignUpView() }
        }
    }
}

struct SignUpView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var action = AsyncAction()
    @State private var confirmationSent = false

    private var passwordIssues: [LocalizedStringKey] {
        PasswordPolicy.issues(for: password).map(\.message)
    }

    var body: some View {
        NavigationStack {
            Form {
                if confirmationSent {
                    Section {
                        Label("auth.confirmEmail", systemImage: "envelope.badge")
                    }
                } else {
                    Section {
                        TextField("auth.name", text: $name)
                            .textContentType(.name)
                        TextField("auth.email", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("auth.password", text: $password)
                            .textContentType(.newPassword)
                    } footer: {
                        VStack(alignment: .leading) {
                            ForEach(Array(passwordIssues.enumerated()), id: \.offset) { _, issue in
                                Text(issue).foregroundStyle(.red)
                            }
                        }
                    }
                    Section {
                        Button("auth.createAccount") {
                            Task {
                                await action.run {
                                    let outcome = try await model.services.auth.signUp(
                                        email: email.trimmingCharacters(in: .whitespaces),
                                        password: password,
                                        displayName: name.trimmingCharacters(in: .whitespaces))
                                    password = ""
                                    if outcome == .confirmEmail {
                                        confirmationSent = true
                                    } else {
                                        await model.refresh()
                                        dismiss()
                                    }
                                }
                            }
                        }
                        .disabled(name.isEmpty || email.isEmpty || !passwordIssues.isEmpty || action.isRunning)
                    }
                }
            }
            .navigationTitle("auth.createAccount")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { dismiss() }
                }
            }
            .errorAlert(action)
        }
    }
}

/// Mirrors the server policy in supabase/config.toml (min 12, lower+upper+digit).
enum PasswordPolicy {
    enum Issue: CaseIterable {
        case tooShort, noLowercase, noUppercase, noDigit

        var message: LocalizedStringKey {
            switch self {
            case .tooShort: "password.tooShort"
            case .noLowercase: "password.noLowercase"
            case .noUppercase: "password.noUppercase"
            case .noDigit: "password.noDigit"
            }
        }
    }

    static let minimumLength = 12

    static func issues(for password: String) -> [Issue] {
        var result: [Issue] = []
        if password.count < minimumLength { result.append(.tooShort) }
        if !password.contains(where: \.isLowercase) { result.append(.noLowercase) }
        if !password.contains(where: \.isUppercase) { result.append(.noUppercase) }
        if !password.contains(where: \.isNumber) { result.append(.noDigit) }
        return result
    }
}
