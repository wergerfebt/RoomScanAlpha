import Foundation

struct RFQ: Identifiable, Codable, Equatable {
    let id: String
    let title: String?
    let description: String?
    let status: String
    let createdAt: String?
    let address: String?
    var scanCount: Int?
    var bidCount: Int?

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return "Untitled Project"
    }

    var hasBids: Bool { (bidCount ?? 0) > 0 }

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, address
        case createdAt = "created_at"
        case scanCount = "scan_count"
        case bidCount = "bid_count"
    }
}

struct RFQContext {
    var rfqId: String
    var rfqDescription: String?
    var floorId: String
    var roomLabel: String
    var originX: Float = 0       // meters — AR world space
    var originY: Float = 0       // meters — AR world space
    var rotationDeg: Float = 0   // degrees
}
