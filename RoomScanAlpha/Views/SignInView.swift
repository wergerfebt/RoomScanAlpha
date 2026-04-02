import SwiftUI
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
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "camera.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("RoomScan")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(isCreatingAccount ? "Create an account" : "Sign in to start scanning")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Email + password fields
            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background(Color(uiColor: .systemGray6))
                    .cornerRadius(10)

                SecureField("Password", text: $password)
                    .textContentType(isCreatingAccount ? .newPassword : .password)
                    .padding()
                    .background(Color(uiColor: .systemGray6))
                    .cornerRadius(10)
            }
            .padding(.horizontal, 40)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // Primary action button
            Button {
                isCreatingAccount ? createAccount() : signIn()
            } label: {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(isCreatingAccount ? "Create Account" : "Sign In")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(.blue)
            .foregroundStyle(.white)
            .fontWeight(.semibold)
            .cornerRadius(10)
            .padding(.horizontal, 40)
            .disabled(isLoading || email.isEmpty || password.isEmpty)

            // Toggle + forgot password
            VStack(spacing: 12) {
                Button {
                    isCreatingAccount.toggle()
                    errorMessage = nil
                } label: {
                    Text(isCreatingAccount ? "Already have an account? Sign In" : "Don't have an account? Create one")
                        .font(.subheadline)
                }

                if !isCreatingAccount {
                    Button {
                        resetEmail = email
                        showResetPassword = true
                    } label: {
                        Text("Forgot password?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Divider
            HStack {
                Rectangle().frame(height: 1).foregroundStyle(.secondary.opacity(0.3))
                Text("or")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Rectangle().frame(height: 1).foregroundStyle(.secondary.opacity(0.3))
            }
            .padding(.horizontal, 40)

            // Google Sign-In
            Button {
                signInWithGoogle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "g.circle.fill")
                        .font(.title3)
                    Text("Sign in with Google")
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color(uiColor: .systemGray6))
                .foregroundStyle(.primary)
                .fontWeight(.medium)
                .cornerRadius(10)
            }
            .padding(.horizontal, 40)
            .disabled(isLoading)

            Spacer()
        }
        .padding()
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
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Complete Your Profile")
                .font(.title2)
                .fontWeight(.bold)

            Text("This helps contractors reach you about quotes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                TextField("Full Name", text: $fullName)
                    .textContentType(.name)
                    .padding()
                    .background(Color(uiColor: .systemGray6))
                    .cornerRadius(10)

                TextField("Phone Number", text: $phone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .padding()
                    .background(Color(uiColor: .systemGray6))
                    .cornerRadius(10)
            }
            .padding(.horizontal, 40)

            Button {
                saveProfile()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .fontWeight(.semibold)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 40)
            .disabled(fullName.trimmingCharacters(in: .whitespaces).isEmpty)

            Button("Skip for now") {
                onComplete()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
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
