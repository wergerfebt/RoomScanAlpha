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
                address: dict["address"] as? String,
                scanCount: dict["scan_count"] as? Int,
                bidCount: dict["bid_count"] as? Int
            )
        }
    }

    /// Fetch full project detail (rooms + scope). Endpoint is link-auth on the
    /// server so no token is strictly required, but we send one when we have it
    /// so the backend can trust the caller's account linkage.
    func getProjectDetail(rfqId: String) async throws -> ProjectDetail {
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/contractor-view")!
        var request = URLRequest(url: url)
        if let token = try? await AuthManager.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Project not found (HTTP \(code))"
            ])
        }
        let decoder = JSONDecoder()
        return try decoder.decode(ProjectDetail.self, from: data)
    }

    /// Fetch bids for an RFQ. JWT-authed — scan-api allows ownership via
    /// user_id OR homeowner_account_id → firebase_uid. Returns empty list
    /// if the caller is not the owner (silently, to keep UIs simple).
    func getBids(rfqId: String) async throws -> [Bid] {
        let token = try await AuthManager.shared.getToken()
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/bids")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 403 { return [] }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Bids fetch failed (HTTP \(http.statusCode))"
            ])
        }
        let decoder = JSONDecoder()
        struct BidsResponse: Codable { let bids: [Bid] }
        return try decoder.decode(BidsResponse.self, from: data).bids
    }

    /// Accept a bid. Server rejects others.
    func acceptBid(rfqId: String, bidId: String) async throws {
        let token = try await AuthManager.shared.getToken()
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/accept-bid")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["bid_id": bidId])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Hire failed (HTTP \(code))"
            ])
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

    /// Update mutable RFQ fields. All args are optional; only non-nil fields
    /// are sent to the server. Server flags pending bids as "project updated".
    func updateRFQ(rfqId: String, title: String? = nil, description: String? = nil, address: String? = nil) async throws {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let description { body["description"] = description }
        if let address { body["address"] = address }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Update failed (HTTP \(code))"
            ])
        }
    }

    /// Rename a scanned room. Backend validates RFQ ownership.
    func renameRoom(rfqId: String, scanId: String, label: String) async throws {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/scans/\(scanId)")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["room_label": label])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Rename failed (HTTP \(code))"
            ])
        }
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
