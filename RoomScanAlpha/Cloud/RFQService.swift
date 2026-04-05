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
                title: dict["title"] as? String,
                description: dict["description"] as? String,
                status: status,
                createdAt: dict["created_at"] as? String,
                address: dict["address"] as? String
            )
        }
    }

    /// Soft-delete a scan. Waits for 200 before returning.
    /// Throws on network failure so the caller can keep the local record.
    func deleteScan(rfqId: String, scanId: String) async throws {
        let token = try await AuthManager.shared.getToken()
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/scans/\(scanId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Delete failed (HTTP \(code))"
            ])
        }
    }

    func createRFQ(title: String, description: String = "", address: String? = nil) async throws -> RFQ {
        let token = try await AuthManager.shared.getToken()
        let url = URL(string: "\(apiBaseURL)/api/rfqs")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["title": title, "description": description]
        if let address, !address.isEmpty {
            body["address"] = address
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return RFQ(
            id: json["id"] as? String ?? "",
            title: json["title"] as? String,
            description: json["description"] as? String,
            status: json["status"] as? String ?? "scan_pending",
            createdAt: nil,
            address: json["address"] as? String
        )
    }

    /// Save scope of work items for a scanned room.
    func saveScope(rfqId: String, scanId: String, scope: RoomScope) async throws {
        let token = try await AuthManager.shared.getToken()
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/scans/\(scanId)/scope")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "items": scope.items,
            "notes": scope.notes
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Save scope failed (HTTP \(code))"
            ])
        }
    }
}
