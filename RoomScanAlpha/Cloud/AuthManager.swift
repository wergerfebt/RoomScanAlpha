import AuthenticationServices
import CryptoKit
import FirebaseAuth
import GoogleSignIn

final class AuthManager {
    static let shared = AuthManager()

    private init() {}

    /// Strong reference to the active Apple Sign-In coordinator. Without
    /// this, `ASAuthorizationController`'s delegate gets deallocated before
    /// the auth UI completes.
    private var activeAppleCoordinator: AppleSignInCoordinator?

    /// UserDefaults key for the most recent Apple authorization code.
    /// Used to revoke the Sign in with Apple token on account deletion,
    /// which Apple requires (Guideline 5.1.1(v)).
    private static let appleAuthCodeKey = "lastAppleAuthorizationCode"

    var isSignedIn: Bool {
        Auth.auth().currentUser != nil
    }

    var currentUser: User? {
        Auth.auth().currentUser
    }

    /// Sign in anonymously. Returns the Firebase user.
    func signInAnonymously() async throws -> User {
        if let user = Auth.auth().currentUser {
            print("[RoomScanAlpha] Already signed in: \(user.uid)")
            return user
        }
        let result = try await Auth.auth().signInAnonymously()
        print("[RoomScanAlpha] Signed in anonymously: \(result.user.uid)")
        return result.user
    }

    /// Sign in with email and password.
    func signIn(email: String, password: String) async throws -> User {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        print("[RoomScanAlpha] Signed in with email: \(result.user.uid)")
        return result.user
    }

    /// Create a new account with email and password.
    func createAccount(email: String, password: String) async throws -> User {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        print("[RoomScanAlpha] Created account: \(result.user.uid)")
        return result.user
    }

    /// Send a password reset email.
    func resetPassword(email: String) async throws {
        try await Auth.auth().sendPasswordReset(withEmail: email)
        print("[RoomScanAlpha] Password reset sent to: \(email)")
    }

    /// Sign in with Google. Presents the Google Sign-In UI.
    func signInWithGoogle() async throws -> User {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            throw AuthError.noRootViewController
        }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)

        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.missingGoogleToken
        }

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )

        let authResult = try await Auth.auth().signIn(with: credential)
        print("[RoomScanAlpha] Signed in with Google: \(authResult.user.uid)")
        return authResult.user
    }

    /// Drive a complete Sign in with Apple flow end-to-end:
    /// 1. generate a fresh raw nonce
    /// 2. present the system Apple ID auth UI
    /// 3. exchange the resulting JWT for a Firebase credential
    ///
    /// The nonce stays local to this call (no shared state across taps),
    /// which is what SwiftUI's `SignInWithAppleButton` cannot guarantee —
    /// hence the move to driving `ASAuthorizationController` ourselves.
    @MainActor
    func signInWithApple() async throws -> User {
        let rawNonce = Self.randomNonceString()
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(rawNonce)

        let authorization: ASAuthorization = try await withCheckedThrowingContinuation { continuation in
            let coordinator = AppleSignInCoordinator(continuation: continuation) { [weak self] in
                self?.activeAppleCoordinator = nil
            }
            self.activeAppleCoordinator = coordinator
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = coordinator
            controller.presentationContextProvider = coordinator
            controller.performRequests()
        }

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = credential.identityToken,
              let idTokenString = String(data: identityToken, encoding: .utf8) else {
            throw AuthError.missingAppleToken
        }

        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: rawNonce,
            fullName: credential.fullName
        )
        let authResult = try await Auth.auth().signIn(with: firebaseCredential)

        // Capture the authorization code so we can revoke the Apple
        // refresh token if the user later deletes their account. Apple
        // tokens last forever otherwise (5.1.1(v) requirement).
        if let codeData = credential.authorizationCode,
           let codeString = String(data: codeData, encoding: .utf8) {
            UserDefaults.standard.set(codeString, forKey: Self.appleAuthCodeKey)
        }

        // First-sign-in only: Apple gives us the name once. Persist it to
        // the Firebase displayName so AccountView/ProfileCompletion can
        // pre-fill it.
        if let fullName = credential.fullName,
           authResult.user.displayName == nil {
            let formatter = PersonNameComponentsFormatter()
            formatter.style = .long
            let displayName = formatter.string(from: fullName)
                .trimmingCharacters(in: .whitespaces)
            if !displayName.isEmpty {
                let changeRequest = authResult.user.createProfileChangeRequest()
                changeRequest.displayName = displayName
                try? await changeRequest.commitChanges()
            }
        }

        print("[RoomScanAlpha] Signed in with Apple: \(authResult.user.uid)")
        return authResult.user
    }

    /// Sign out the current user.
    func signOut() throws {
        try Auth.auth().signOut()
        print("[RoomScanAlpha] Signed out")
    }

    /// Delete the Firebase user. Server-side data must be scrubbed first via
    /// `AccountService.deleteAccount()`. If the ID token is too old, Firebase
    /// throws `requiresRecentLogin`; the caller must re-auth and retry.
    func deleteFirebaseUser() async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notSignedIn
        }
        try await user.delete()
        print("[RoomScanAlpha] Firebase user deleted")
    }

    /// Revoke the most recent Apple Sign-In refresh token if one is stored.
    /// Best-effort: the authorization code is short-lived (~5 min), so this
    /// often fails for users who signed in long ago. Non-fatal — Apple lets
    /// users revoke manually in iOS Settings → Apple ID → Sign in with Apple.
    func revokeAppleTokenIfNeeded() async {
        guard let code = UserDefaults.standard.string(forKey: Self.appleAuthCodeKey) else {
            return
        }
        do {
            try await Auth.auth().revokeToken(withAuthorizationCode: code)
            UserDefaults.standard.removeObject(forKey: Self.appleAuthCodeKey)
            print("[RoomScanAlpha] Apple token revoked")
        } catch {
            print("[RoomScanAlpha] Apple token revoke failed: \(error.localizedDescription)")
        }
    }

    /// Get a fresh JWT token for API requests.
    func getToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notSignedIn
        }
        let token = try await user.getIDToken()
        return token
    }

    enum AuthError: LocalizedError {
        case notSignedIn
        case noRootViewController
        case missingGoogleToken
        case missingAppleToken

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in. Please sign in first."
            case .noRootViewController:
                return "Unable to present sign-in. Please try again."
            case .missingGoogleToken:
                return "Google sign-in failed. Please try again."
            case .missingAppleToken:
                return "Apple sign-in failed. Please try again."
            }
        }
    }

    // MARK: - Apple Sign-In nonce helpers

    /// Cryptographically random URL-safe nonce. Apple requires the SHA-256
    /// hash to be passed as `nonce` on the request, and the raw value to be
    /// passed to Firebase when constructing the credential — Firebase
    /// re-hashes and compares against the JWT.
    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            if status != errSecSuccess {
                fatalError("SecRandomCopyBytes failed with status \(status)")
            }
            for byte in bytes where remaining > 0 {
                if byte < charset.count {
                    result.append(charset[Int(byte)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}
