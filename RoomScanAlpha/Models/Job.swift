import Foundation

/// One row in the contractor Jobs list — mirrors the `Job` shape the web
/// OrgDashboard uses. Fields are narrow to what iOS actually renders.
struct Job: Identifiable, Codable, Equatable {
    let rfqId: String
    let title: String
    let description: String?
    let address: String?
    let createdAt: String?
    let jobStatus: String          // new | pending | won | lost
    let rfqDeleted: Bool?
    let bid: JobBid?

    var id: String { "\(rfqId)-\(jobStatus)" }

    struct JobBid: Codable, Equatable {
        let id: String
        let priceCents: Int
        let status: String?
        let receivedAt: String?
        let description: String?
        let pdfURL: String?
        let rfqModifiedAfterBid: Bool?

        enum CodingKeys: String, CodingKey {
            case id, status, description
            case priceCents = "price_cents"
            case receivedAt = "received_at"
            case pdfURL = "pdf_url"
            case rfqModifiedAfterBid = "rfq_modified_after_bid"
        }
    }

    enum CodingKeys: String, CodingKey {
        case title, description, address, bid
        case rfqId = "rfq_id"
        case createdAt = "created_at"
        case jobStatus = "job_status"
        case rfqDeleted = "rfq_deleted"
    }
}
