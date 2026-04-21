import Foundation

/// Thin wrapper around `/api/account` — fetches the signed-in user's unified
/// account + org membership so the iOS app can decide whether to surface
/// contractor-workspace entry points.
final class AccountService {
    static let shared = AccountService()
    private let apiBaseURL = "https://scan-api-839349778883.us-central1.run.app"
    private init() {}

    func getAccount() async throws -> Account {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/account")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Account.self, from: data)
    }
}
