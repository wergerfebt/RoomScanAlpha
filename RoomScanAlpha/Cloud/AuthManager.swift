import FirebaseAuth

final class AuthManager {
    static let shared = AuthManager()

    private init() {}

    var isSignedIn: Bool {
        Auth.auth().currentUser != nil
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

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in. Please sign in first."
            }
        }
    }
}
