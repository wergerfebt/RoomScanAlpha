import Foundation

struct RFQ: Identifiable, Codable, Equatable {
    let id: String
    let description: String?
    let status: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, description, status
        case createdAt = "created_at"
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
