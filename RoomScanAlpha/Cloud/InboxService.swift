import Foundation

/// Wraps the homeowner inbox endpoints on scan-api.
/// Contractor-side (role=org) and homeowner-side (role=homeowner) share the
/// same routes; iOS defaults to homeowner.
final class InboxService {
    static let shared = InboxService()
    private let apiBaseURL = "https://scan-api-839349778883.us-central1.run.app"
    private init() {}

    /// `/api/inbox?role=homeowner`
    func listThreads() async throws -> [InboxThread] {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/inbox?role=homeowner")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Envelope: Codable { let conversations: [InboxThread] }
        return try JSONDecoder().decode(Envelope.self, from: data).conversations
    }

    /// `/api/conversations/{id}` — full thread. Server marks caller-side read.
    func getConversation(id: String) async throws -> Conversation {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/conversations/\(id)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Conversation.self, from: data)
    }

    /// `POST /api/conversations/{id}/messages` — plain text (no attachments).
    func sendMessage(conversationId: String, body: String) async throws {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/conversations/\(conversationId)/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["body": body, "attachments": []])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Send failed (HTTP \(code))"
            ])
        }
    }
}
