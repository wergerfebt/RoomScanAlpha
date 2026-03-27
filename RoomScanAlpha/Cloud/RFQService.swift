import Foundation

final class RFQService {
    static let shared = RFQService()
    private let apiBaseURL = "https://scan-api-839349778883.us-central1.run.app"

    private init() {}

    func listRFQs() async throws -> [RFQ] {
        let token = try await AuthManager.shared.getToken()
        let url = URL(string: "\(apiBaseURL)/api/rfqs")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let rfqsArray = json["rfqs"] as? [[String: Any]] else { return [] }

        return rfqsArray.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let status = dict["status"] as? String else { return nil }
            return RFQ(
                id: id,
                description: dict["description"] as? String,
                status: status,
                createdAt: dict["created_at"] as? String
            )
        }
    }

    func createRFQ(description: String) async throws -> RFQ {
        let token = try await AuthManager.shared.getToken()
        let url = URL(string: "\(apiBaseURL)/api/rfqs")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["description": description])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return RFQ(
            id: json["id"] as? String ?? "",
            description: json["description"] as? String,
            status: json["status"] as? String ?? "scan_pending",
            createdAt: nil
        )
    }
}
