import Foundation

/// Public (no auth required) endpoints for browsing contractors.
final class ContractorsService {
    static let shared = ContractorsService()
    private let apiBaseURL = "https://scan-api-839349778883.us-central1.run.app"
    private init() {}

    /// `/api/contractors/search?service=&location=&q=`
    func search(service: String?, location: String?, query: String?) async throws -> [ContractorSearchResult] {
        var components = URLComponents(string: "\(apiBaseURL)/api/contractors/search")!
        var items: [URLQueryItem] = []
        if let service, !service.isEmpty { items.append(URLQueryItem(name: "service", value: service)) }
        if let location, !location.isEmpty { items.append(URLQueryItem(name: "location", value: location)) }
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if !items.isEmpty { components.queryItems = items }

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        // The API returns either a bare array or an object with `contractors`.
        // Try the array first.
        let decoder = JSONDecoder()
        if let results = try? decoder.decode([ContractorSearchResult].self, from: data) {
            return results
        }
        struct Envelope: Codable { let contractors: [ContractorSearchResult]? }
        if let env = try? decoder.decode(Envelope.self, from: data) {
            return env.contractors ?? []
        }
        return []
    }

    /// `/api/orgs/{org_id}` — public profile.
    func getOrg(id: String) async throws -> OrgProfile {
        let url = URL(string: "\(apiBaseURL)/api/orgs/\(id)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(OrgProfile.self, from: data)
    }
}

/// Static list of the 14 service categories that match the web app.
/// Matches `cloud/frontend/src/api/services.ts`.
enum ServiceCategory {
    static let all: [String] = [
        "Kitchen Remodel",
        "Bathroom Remodel",
        "Full Home Remodel",
        "Basement Finishing",
        "Flooring",
        "Painting",
        "Cabinetry",
        "Countertops",
        "Tile Work",
        "Window Installation",
        "Door Installation",
        "Electrical Work",
        "Plumbing",
        "Carpet Cleaning",
    ]
}
