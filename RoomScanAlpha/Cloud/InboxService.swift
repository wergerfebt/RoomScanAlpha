import Foundation

/// Wraps the homeowner inbox endpoints on scan-api.
/// Contractor-side (role=org) and homeowner-side (role=homeowner) share the
/// same routes; iOS defaults to homeowner.
final class InboxService {
    static let shared = InboxService()
    private let apiBaseURL = "https://scan-api-839349778883.us-central1.run.app"
    private init() {}

    /// Inbox role — scopes `/api/inbox` to the caller's side.
    enum Role: String { case homeowner, org }

    /// `/api/inbox?role=...`
    func listThreads(role: Role = .homeowner) async throws -> [InboxThread] {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/inbox?role=\(role.rawValue)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Envelope: Codable { let conversations: [InboxThread] }
        return try JSONDecoder().decode(Envelope.self, from: data).conversations
    }

    /// `POST /api/conversations` — open (or create) a thread for an rfq × org.
    /// Idempotent. Caller must be either the RFQ owner or a member of `orgId`.
    func createConversation(rfqId: String, orgId: String) async throws -> String {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/conversations")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String] = ["rfq_id": rfqId, "org_id": orgId]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't open conversation (HTTP \(code))"
            ])
        }
        struct Envelope: Codable { let id: String }
        return try JSONDecoder().decode(Envelope.self, from: data).id
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

    /// Reserve a GCS upload slot for a conversation attachment and return the
    /// signed PUT URL + blob_path scoped to this conversation.
    /// Matches `GET /api/conversations/{id}/attachment-upload-url?content_type=&filename=`.
    struct UploadSlot: Codable {
        let uploadURL: String
        let blobPath: String
        let contentType: String
        let filename: String?
        enum CodingKeys: String, CodingKey {
            case uploadURL = "upload_url"
            case blobPath = "blob_path"
            case contentType = "content_type"
            case filename
        }
    }

    func attachmentUploadURL(conversationId: String, contentType: String, filename: String) async throws -> UploadSlot {
        let token = try await AuthManager.shared.getToken()
        var comps = URLComponents(string: "\(apiBaseURL)/api/conversations/\(conversationId)/attachment-upload-url")!
        comps.queryItems = [
            URLQueryItem(name: "content_type", value: contentType),
            URLQueryItem(name: "filename", value: filename),
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(UploadSlot.self, from: data)
    }

    /// PUT binary content to a signed URL returned by `attachmentUploadURL`.
    func uploadAttachment(to url: URL, contentType: String, data: Data) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Upload failed (HTTP \(code))"
            ])
        }
    }

    struct AttachmentRef {
        let blobPath: String
        let contentType: String
        let name: String
        let sizeBytes: Int
    }

    /// `POST /api/conversations/{id}/messages` with optional attachments.
    /// The backend validates that every blob_path is scoped to this conversation.
    func sendMessage(conversationId: String, body: String, attachments: [AttachmentRef] = []) async throws {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/conversations/\(conversationId)/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "body": body,
            "attachments": attachments.map { att in
                [
                    "blob_path": att.blobPath,
                    "content_type": att.contentType,
                    "name": att.name,
                    "size_bytes": att.sizeBytes,
                ]
            },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Send failed (HTTP \(code))"
            ])
        }
    }
}
