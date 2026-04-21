import Foundation

/// Thread summary returned by `/api/inbox`.
struct InboxThread: Identifiable, Codable, Equatable {
    let id: String
    let rfqId: String
    let rfqTitle: String
    let rfqAddress: String?
    let counterpart: Counterpart
    let lastMessageAt: String?
    let lastMessagePreview: String?
    let lastMessageSide: String?
    let unreadCount: Int
    let kind: String            // rfq | bid | won | msg
    let kindLabel: String
    let latestBid: LatestBid?
    let createdAt: String?

    struct Counterpart: Codable, Equatable {
        let type: String        // "org" | "homeowner"
        let id: String
        let name: String?
        let email: String?
        let iconURL: String?

        enum CodingKeys: String, CodingKey {
            case type, id, name, email
            case iconURL = "icon_url"
        }
    }

    struct LatestBid: Codable, Equatable {
        let id: String
        let priceCents: Int?
        let status: String?

        enum CodingKeys: String, CodingKey {
            case id, status
            case priceCents = "price_cents"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, counterpart, kind
        case rfqId = "rfq_id"
        case rfqTitle = "rfq_title"
        case rfqAddress = "rfq_address"
        case lastMessageAt = "last_message_at"
        case lastMessagePreview = "last_message_preview"
        case lastMessageSide = "last_message_side"
        case unreadCount = "unread_count"
        case kindLabel = "kind_label"
        case latestBid = "latest_bid"
        case createdAt = "created_at"
    }
}

/// Full conversation body returned by `/api/conversations/{id}`.
struct Conversation: Codable, Equatable {
    let id: String
    let rfq: RFQRef
    let homeowner: Party
    let org: Party
    let messages: [Message]
    let callerSide: String       // "homeowner" | "org"

    struct RFQRef: Codable, Equatable { let id: String; let title: String; let address: String? }
    struct Party: Codable, Equatable {
        let id: String
        let name: String?
        let email: String?
        let iconURL: String?
        enum CodingKeys: String, CodingKey { case id, name, email; case iconURL = "icon_url" }
    }

    enum CodingKeys: String, CodingKey {
        case id, rfq, homeowner, org, messages
        case callerSide = "caller_side"
    }
}

struct Message: Identifiable, Codable, Equatable {
    let id: String
    let side: String            // "homeowner" | "org" | "system"
    let kind: String            // "text" | "event" | "bid"
    let body: String?
    let eventType: String?
    let bidId: String?
    let bidSnapshot: BidSnapshot?
    let attachments: [Attachment]
    let createdAt: String?
    let sender: Sender?

    struct BidSnapshot: Codable, Equatable {
        let priceCents: Int?
        let status: String?
        let description: String?
        enum CodingKeys: String, CodingKey {
            case status, description
            case priceCents = "price_cents"
        }
    }

    struct Attachment: Codable, Equatable, Identifiable {
        let blobPath: String
        let downloadURL: String?
        let contentType: String?
        let name: String?
        let sizeBytes: Int?
        var id: String { blobPath }
        enum CodingKeys: String, CodingKey {
            case name
            case blobPath = "blob_path"
            case downloadURL = "download_url"
            case contentType = "content_type"
            case sizeBytes = "size_bytes"
        }
    }

    struct Sender: Codable, Equatable {
        let id: String
        let name: String?
        let email: String?
        let iconURL: String?
        enum CodingKeys: String, CodingKey { case id, name, email; case iconURL = "icon_url" }
    }

    enum CodingKeys: String, CodingKey {
        case id, side, kind, body, attachments, sender
        case eventType = "event_type"
        case bidId = "bid_id"
        case bidSnapshot = "bid_snapshot"
        case createdAt = "created_at"
    }
}
