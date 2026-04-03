import FirebaseAuth
import GoogleSignIn

final class AuthManager {
    static let shared = AuthManager()

    private init() {}

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

    /// Sign out the current user.
    func signOut() throws {
        try Auth.auth().signOut()
        print("[RoomScanAlpha] Signed out")
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

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in. Please sign in first."
            case .noRootViewController:
                return "Unable to present sign-in. Please try again."
            case .missingGoogleToken:
                return "Google sign-in failed. Please try again."
            }
        }
    }
}
