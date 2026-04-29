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

    /// `DELETE /api/account` — scrub the caller's RFQs, drop org memberships,
    /// remove the account row. Caller must also delete the Firebase user.
    func deleteAccount() async throws {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/account")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    /// `PUT /api/account` — update name, phone, icon_url, etc.
    func updateAccount(fields: [String: Any]) async throws {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/account")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    /// `GET /api/account/icon-upload-url` — reserve a signed GCS URL for the
    /// account avatar. PUT the image bytes to `uploadURL` then call
    /// `updateAccount(iconURL: <blob GCS public url>)`.
    struct IconUploadSlot: Codable {
        let uploadURL: String
        let blobPath: String
        let contentType: String
        enum CodingKeys: String, CodingKey {
            case uploadURL = "upload_url"
            case blobPath = "blob_path"
            case contentType = "content_type"
        }
    }

    func iconUploadURL(contentType: String) async throws -> IconUploadSlot {
        let token = try await AuthManager.shared.getToken()
        var comps = URLComponents(string: "\(apiBaseURL)/api/account/icon-upload-url")!
        comps.queryItems = [URLQueryItem(name: "content_type", value: contentType)]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(IconUploadSlot.self, from: data)
    }

    /// PUT image bytes to a pre-signed GCS URL.
    func uploadIcon(to url: URL, contentType: String, data: Data) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
