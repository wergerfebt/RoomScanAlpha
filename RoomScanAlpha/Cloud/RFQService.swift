import Foundation

fileprivate extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

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

    // MARK: – Project media (rfq_attachments)

    struct RFQAttachment: Codable, Equatable, Identifiable {
        let attachmentId: String
        let blobPath: String
        let contentType: String?
        let name: String?
        let sizeBytes: Int?
        let downloadURL: String?
        var id: String { attachmentId }

        enum CodingKeys: String, CodingKey {
            case attachmentId = "attachment_id"
            case blobPath = "blob_path"
            case contentType = "content_type"
            case name
            case sizeBytes = "size_bytes"
            case downloadURL = "download_url"
        }
    }

    /// `GET /api/rfqs/{id}/attachments` — accessible to owner + contractors
    /// with a bid/conversation on this RFQ.
    func listProjectAttachments(rfqId: String) async throws -> [RFQAttachment] {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/attachments")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 403 { return [] }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Envelope: Codable { let attachments: [RFQAttachment] }
        return try JSONDecoder().decode(Envelope.self, from: data).attachments
    }

    struct AttachmentUploadSlot: Codable {
        let uploadURL: String
        let blobPath: String
        let contentType: String
        enum CodingKeys: String, CodingKey {
            case uploadURL = "upload_url"
            case blobPath = "blob_path"
            case contentType = "content_type"
        }
    }

    func attachmentUploadURL(rfqId: String, contentType: String, filename: String?) async throws -> AttachmentUploadSlot {
        let token = try await AuthManager.shared.getToken()
        var comps = URLComponents(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/attachment-upload-url")!
        comps.queryItems = [URLQueryItem(name: "content_type", value: contentType)]
        if let filename { comps.queryItems?.append(URLQueryItem(name: "filename", value: filename)) }
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(AttachmentUploadSlot.self, from: data)
    }

    func uploadAttachmentBytes(to url: URL, contentType: String, data: Data) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    /// `POST /api/rfqs/{id}/attachments` — link a just-uploaded blob.
    func registerProjectAttachments(rfqId: String, items: [(blobPath: String, contentType: String, name: String?, sizeBytes: Int?)]) async throws {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/attachments")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let attachments = items.map { item -> [String: Any] in
            var dict: [String: Any] = [
                "blob_path": item.blobPath,
                "content_type": item.contentType,
            ]
            if let name = item.name { dict["name"] = name }
            if let s = item.sizeBytes { dict["size_bytes"] = s }
            return dict
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["attachments": attachments])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    /// `DELETE /api/rfqs/{id}/attachments/{attachmentId}`
    func deleteProjectAttachment(rfqId: String, attachmentId: String) async throws {
        let token = try await AuthManager.shared.getToken()
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/attachments/\(attachmentId)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    /// Submit or update a bid for an RFQ. Multipart form-data matches the
    /// web contract: price_cents + description (optional Timeline/Start prefix)
    /// + optional PDF + zero or more images.
    struct BidImage {
        let data: Data
        let contentType: String
        let filename: String
    }

    func submitBid(
        rfqId: String,
        priceCents: Int,
        description: String,
        pdf: (data: Data, contentType: String, filename: String)? = nil,
        images: [BidImage] = []
    ) async throws {
        let token = try await AuthManager.shared.getToken()
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func addField(_ name: String, value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        func addFile(name: String, filename: String, contentType: String, data: Data) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            body.appendString("Content-Type: \(contentType)\r\n\r\n")
            body.append(data)
            body.appendString("\r\n")
        }

        addField("price_cents", value: String(priceCents))
        addField("description", value: description)
        if let pdf {
            addFile(name: "pdf", filename: pdf.filename, contentType: pdf.contentType, data: pdf.data)
        }
        for img in images {
            addFile(name: "images", filename: img.filename, contentType: img.contentType, data: img.data)
        }
        body.appendString("--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/bids")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Bid submit failed (HTTP \(code))"
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
