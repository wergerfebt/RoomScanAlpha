import SwiftUI
import AuthenticationServices
import FirebaseAuth
import GoogleSignIn

struct SignInView: View {
    let onSignedIn: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isCreatingAccount = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showResetPassword = false
    @State private var resetEmail = ""
    @State private var resetSent = false
    @State private var showProfileCompletion = false

    var body: some View {
        if showProfileCompletion {
            ProfileCompletionView {
                onSignedIn()
            }
        } else {
            signInContent
        }
    }

    private var signInContent: some View {
        ZStack {
            QTheme.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 40)

                    // Quoterra Q tile — matches HomeView header
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(QTheme.primary)
                        Text("Q")
                            .font(.system(size: 28, weight: .black))
                            .foregroundStyle(QTheme.primaryInk)
                    }
                    .frame(width: 56, height: 56)

                    VStack(spacing: 6) {
                        Text("Quoterra")
                            .font(.system(size: 34, weight: .bold))
                            .tracking(-0.8)
                            .foregroundStyle(QTheme.ink)
                        Text(isCreatingAccount ? "Create an account" : "Sign in to manage your projects")
                            .font(.system(size: 15))
                            .foregroundStyle(QTheme.inkMuted)
                    }

                    // Email + password fields
                    VStack(spacing: 10) {
                        authField(icon: "envelope", placeholder: "Email", text: $email, secure: false)
                        authField(icon: "lock", placeholder: "Password", text: $password, secure: true)
                    }
                    .padding(.horizontal, 28)

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(QTheme.danger)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }

                    // Primary action
                    Button {
                        isCreatingAccount ? createAccount() : signIn()
                    } label: {
                        ZStack {
                            if isLoading {
                                ProgressView().tint(QTheme.primaryInk)
                            } else {
                                Text(isCreatingAccount ? "Create account" : "Sign in")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(QTheme.primary)
                        .foregroundStyle(QTheme.primaryInk)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 28)
                    .disabled(isLoading || email.isEmpty || password.isEmpty)

                    // Toggle + forgot password
                    VStack(spacing: 10) {
                        Button {
                            isCreatingAccount.toggle()
                            errorMessage = nil
                        } label: {
                            Text(isCreatingAccount ? "Already have an account? Sign in" : "Don't have an account? Create one")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(QTheme.primary)
                        }

                        if !isCreatingAccount {
                            Button {
                                resetEmail = email
                                showResetPassword = true
                            } label: {
                                Text("Forgot password?")
                                    .font(.system(size: 13))
                                    .foregroundStyle(QTheme.inkMuted)
                            }
                        }
                    }

                    // Divider
                    HStack(spacing: 10) {
                        Rectangle().frame(height: 0.5).foregroundStyle(QTheme.hairline)
                        Text("or")
                            .font(.system(size: 12))
                            .foregroundStyle(QTheme.inkMuted)
                        Rectangle().frame(height: 0.5).foregroundStyle(QTheme.hairline)
                    }
                    .padding(.horizontal, 40)

                    // Sign in with Apple — required by App Store Guideline 4.8
                    // whenever a third-party social sign-in (Google here) is offered.
                    AppleIDButton(cornerRadius: 14) {
                        signInWithApple()
                    }
                    .frame(height: 50)
                    .padding(.horizontal, 28)
                    .disabled(isLoading)
                    .opacity(isLoading ? 0.5 : 1)

                    // Google Sign-In
                    Button {
                        signInWithGoogle()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "g.circle.fill")
                                .font(.system(size: 18))
                            Text("Sign in with Google")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(QTheme.surface)
                        .foregroundStyle(QTheme.ink)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(QTheme.hairline, lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 28)
                    .disabled(isLoading)

                    Spacer(minLength: 24)
                }
            }
        }
        .onAppear {
            if AuthManager.shared.isSignedIn {
                onSignedIn()
            }
        }
        .alert("Reset Password", isPresented: $showResetPassword) {
            TextField("Email", text: $resetEmail)
            Button("Send Reset Link") {
                Task {
                    try? await AuthManager.shared.resetPassword(email: resetEmail)
                    resetSent = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter your email to receive a password reset link.")
        }
        .alert("Check Your Email", isPresented: $resetSent) {
            Button("OK") {}
        } message: {
            Text("A password reset link has been sent to \(resetEmail).")
        }
    }

    private func authField(icon: String, placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(QTheme.inkMuted)
                .font(.system(size: 15))
                .frame(width: 18)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                        .textContentType(isCreatingAccount ? .newPassword : .password)
                } else {
                    TextField(placeholder, text: text)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .foregroundStyle(QTheme.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(QTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(QTheme.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func signIn() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                _ = try await AuthManager.shared.signIn(email: email, password: password)
                onSignedIn()
            } catch {
                errorMessage = friendlyError(error)
            }
            isLoading = false
        }
    }

    private func signInWithApple() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                _ = try await AuthManager.shared.signInWithApple()
                onSignedIn()
            } catch {
                // User-cancelled is silent — Apple sets ASAuthorizationError.canceled.
                let nsError = error as NSError
                if nsError.domain != ASAuthorizationError.errorDomain
                    || nsError.code != ASAuthorizationError.canceled.rawValue {
                    errorMessage = error.localizedDescription
                }
            }
            isLoading = false
        }
    }

    private func signInWithGoogle() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                _ = try await AuthManager.shared.signInWithGoogle()
                onSignedIn()
            } catch {
                // Don't show error if user cancelled
                let nsError = error as NSError
                if nsError.code != GIDSignInError.canceled.rawValue {
                    errorMessage = error.localizedDescription
                }
            }
            isLoading = false
        }
    }

    private func createAccount() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                _ = try await AuthManager.shared.createAccount(email: email, password: password)
                // New account — need name and phone
                showProfileCompletion = true
            } catch {
                errorMessage = friendlyError(error)
            }
            isLoading = false
        }
    }

    private func friendlyError(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case 17007: return "An account with this email already exists."
        case 17009: return "Incorrect password."
        case 17011: return "No account found with this email."
        case 17026: return "Password must be at least 6 characters."
        case 17008: return "Please enter a valid email address."
        default: return error.localizedDescription
        }
    }
}

// MARK: - Profile Completion (shown once after email/password sign-up)

private struct ProfileCompletionView: View {
    let onComplete: () -> Void

    @State private var fullName = ""
    @State private var phone = ""

    var body: some View {
        ZStack {
            QTheme.canvas.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer(minLength: 40)

                ZStack {
                    Circle().fill(QTheme.primarySoft)
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(QTheme.primary)
                }
                .frame(width: 64, height: 64)

                VStack(spacing: 6) {
                    Text("Complete your profile")
                        .font(.system(size: 24, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(QTheme.ink)
                    Text("This helps contractors reach you about quotes.")
                        .font(.system(size: 14))
                        .foregroundStyle(QTheme.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                VStack(spacing: 10) {
                    profileField(icon: "person", placeholder: "Full name", text: $fullName, keyboard: .default)
                    profileField(icon: "phone", placeholder: "Phone number (optional)", text: $phone, keyboard: .phonePad)
                }
                .padding(.horizontal, 28)

                Button {
                    saveProfile()
                } label: {
                    Text("Continue")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(QTheme.primary)
                        .foregroundStyle(QTheme.primaryInk)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .opacity(fullName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .disabled(fullName.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Skip for now") { onComplete() }
                    .font(.system(size: 14))
                    .foregroundStyle(QTheme.inkMuted)

                Spacer()
            }
        }
    }

    private func profileField(icon: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(QTheme.inkMuted)
                .font(.system(size: 15))
                .frame(width: 18)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textContentType(icon == "person" ? .name : .telephoneNumber)
                .foregroundStyle(QTheme.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(QTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(QTheme.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func saveProfile() {
        // Save display name to Firebase Auth profile
        if let user = Auth.auth().currentUser {
            let changeRequest = user.createProfileChangeRequest()
            changeRequest.displayName = fullName
            changeRequest.commitChanges { _ in }
        }
        // Store phone in UserDefaults (Firebase Auth doesn't have a phone field for email users)
        if !phone.isEmpty {
            UserDefaults.standard.set(phone, forKey: "userPhone")
        }
        onComplete()
    }
}

// MARK: - Sign in with Apple button

/// Wraps UIKit's `ASAuthorizationAppleIDButton` so we get the official
/// Apple-styled button (matches HIG) but drive the auth flow ourselves
/// via `AuthManager.signInWithApple()`. SwiftUI's own `SignInWithAppleButton`
/// can desync the nonce between its `onRequest` and `onCompletion` closures,
/// which causes Firebase to reject the JWT with a nonce-mismatch error.
private struct AppleIDButton: UIViewRepresentable {
    let cornerRadius: CGFloat
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: .black)
        button.cornerRadius = cornerRadius
        button.addTarget(context.coordinator,
                         action: #selector(Coordinator.tapped),
                         for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}
