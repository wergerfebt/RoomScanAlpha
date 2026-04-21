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
        struct Envelope: Codable { let images: [GalleryItem] }
        return try JSONDecoder().decode(Envelope.self, from: data).images
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
