import Foundation

/// A bid submitted by a contractor on an RFQ.
struct Bid: Identifiable, Codable, Equatable {
    let id: String
    let priceCents: Int
    let description: String?
    let pdfURL: String?
    let receivedAt: String?
    let status: String?               // pending / accepted / rejected
    let contractor: ContractorSummary

    var displayPrice: String {
        let dollars = Double(priceCents) / 100.0
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: dollars)) ?? "$\(priceCents/100)"
    }

    var isAccepted: Bool { status == "accepted" }

    enum CodingKeys: String, CodingKey {
        case id, description, status, contractor
        case priceCents = "price_cents"
        case pdfURL = "pdf_url"
        case receivedAt = "received_at"
    }
}

/// The contractor-side summary returned embedded in a bid.
struct ContractorSummary: Codable, Equatable {
    let id: String
    let name: String?
    let iconURL: String?
    let reviewRating: Double?
    let reviewCount: Int?
    let description: String?

    var displayName: String { name ?? "Contractor" }
    var initials: String {
        let parts = (name ?? "?").split(separator: " ").map(String.init)
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case iconURL = "icon_url"
        case reviewRating = "review_rating"
        case reviewCount = "review_count"
    }
}

/// Parses the structured timeline/start prefix the web bid form writes into
/// `description`. Falls back to the raw text as `note`.
struct ParsedBidNote {
    var timeline: String = ""
    var start: String = ""
    var note: String = ""

    init(from description: String?) {
        guard let text = description, !text.isEmpty else { return }
        // Pattern: "Timeline: <tl> · Start: <st>\n\n<note>"
        // or just: "Timeline: <tl>\n\n<note>"
        let header = text.components(separatedBy: "\n\n").first ?? ""
        if header.hasPrefix("Timeline:") || header.hasPrefix("Start:") {
            let rest = text.dropFirst(header.count).drop(while: { $0 == "\n" })
            note = String(rest)

            // Parse the header for Timeline + Start
            let segments = header.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            for seg in segments {
                if seg.hasPrefix("Timeline:") {
                    timeline = String(seg.dropFirst("Timeline:".count)).trimmingCharacters(in: .whitespaces)
                } else if seg.hasPrefix("Start:") {
                    start = String(seg.dropFirst("Start:".count)).trimmingCharacters(in: .whitespaces)
                }
            }
        } else {
            note = text
        }
    }
}
