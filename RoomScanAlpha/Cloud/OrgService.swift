import Foundation

/// Contractor-side endpoints. Scoped by the caller's org membership on the
/// server — no org_id in the URL.
final class OrgService {
    static let shared = OrgService()
    private let apiBaseURL = "https://scan-api-839349778883.us-central1.run.app"
    private init() {}

    /// `GET /api/org` — the caller's org profile.
    func getOrg() async throws -> OrgProfile {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/org")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(OrgProfile.self, from: data)
    }

    /// `GET /api/org/jobs` — contractor jobs list.
    func listJobs() async throws -> [Job] {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/org/jobs")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Envelope: Codable { let jobs: [Job] }
        return try JSONDecoder().decode(Envelope.self, from: data).jobs
    }

    /// `GET /api/org/members`
    func listMembers() async throws -> [OrgMember] {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/org/members")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Envelope: Codable { let members: [OrgMember] }
        return try JSONDecoder().decode(Envelope.self, from: data).members
    }

    /// `GET /api/org/gallery` — portfolio images.
    func listGallery() async throws -> [GalleryItem] {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/org/gallery")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Envelope: Codable { let media: [GalleryItem] }
        return try JSONDecoder().decode(Envelope.self, from: data).media
    }

    /// `PUT /api/org` — admin update of org profile fields.
    func updateOrg(fields: [String: Any]) async throws {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/org")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Update org failed (HTTP \(code))"
            ])
        }
    }

    /// Signed-URL slot for org icon/banner/gallery uploads.
    struct UploadSlot: Codable {
        let uploadURL: String
        let blobPath: String
        let contentType: String
        let imageId: String?
        enum CodingKeys: String, CodingKey {
            case uploadURL = "upload_url"
            case blobPath = "blob_path"
            case contentType = "content_type"
            case imageId = "image_id"
        }
    }

    func orgIconUploadURL(contentType: String) async throws -> UploadSlot {
        try await signedSlot(path: "/api/org/icon-upload-url", contentType: contentType)
    }

    func orgGalleryUploadURL(contentType: String) async throws -> UploadSlot {
        try await signedSlot(path: "/api/org/gallery/upload-url", contentType: contentType)
    }

    private func signedSlot(path: String, contentType: String) async throws -> UploadSlot {
        let token = try await AuthManager.shared.getToken()
        var comps = URLComponents(string: "\(apiBaseURL)\(path)")!
        comps.queryItems = [URLQueryItem(name: "content_type", value: contentType)]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(UploadSlot.self, from: data)
    }

    /// PUT binary to signed URL. Shared with the gallery + avatar flows.
    func uploadBytes(to url: URL, contentType: String, data: Data) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    /// `POST /api/org/gallery` — create a gallery record for a just-uploaded blob.
    func addGalleryItem(imageBlobPath: String, caption: String? = nil) async throws {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/org/gallery")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "image_url": imageBlobPath,
            "image_type": "single",
            "media_type": "image",
        ]
        if let caption { payload["caption"] = caption }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    /// `DELETE /api/org/gallery/{id}` — remove a gallery item.
    func deleteGalleryItem(imageId: String) async throws {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/org/gallery/\(imageId)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    /// `GET /api/services` — full service catalog (public).
    func listAllServices() async throws -> [ServiceRecord] {
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/services")!)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Envelope: Codable { let services: [ServiceRecord] }
        return try JSONDecoder().decode(Envelope.self, from: data).services
    }

    /// `PUT /api/org/services` — replace the org's service list.
    func updateOrgServices(serviceIds: [String]) async throws {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/org/services")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["service_ids": serviceIds])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    /// `GET /api/org/services`
    func listOrgServices() async throws -> [OrgProfile.Service] {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/org/services")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Envelope: Codable { let services: [OrgProfile.Service] }
        return try JSONDecoder().decode(Envelope.self, from: data).services
    }
}

struct ServiceRecord: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let iconURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case iconURL = "icon_url"
    }
}

struct OrgMember: Codable, Equatable, Identifiable {
    let id: String
    let name: String?
    let email: String
    let iconURL: String?
    let role: String
    let inviteStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email, role
        case iconURL = "icon_url"
        case inviteStatus = "invite_status"
    }
}

struct GalleryItem: Codable, Equatable, Identifiable {
    let id: String
    let imageURL: String?
    let beforeImageURL: String?
    let caption: String?
    let imageType: String?

    enum CodingKeys: String, CodingKey {
        case id, caption
        case imageURL = "image_url"
        case beforeImageURL = "before_image_url"
        case imageType = "image_type"
    }
}
