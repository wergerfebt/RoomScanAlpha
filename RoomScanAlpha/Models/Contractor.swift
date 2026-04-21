import Foundation

/// Summary row returned by `/api/contractors/search`.
struct ContractorSearchResult: Identifiable, Codable, Equatable {
    let id: String
    let name: String?
    let iconURL: String?
    let description: String?
    let address: String?
    let avgRating: Double?
    let reviewCount: Int?

    var displayName: String { name ?? "Contractor" }
    var initials: String {
        let parts = (name ?? "?").split(separator: " ").prefix(2).compactMap { $0.first }
        return String(parts).uppercased()
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, address
        case iconURL = "icon_url"
        case avgRating = "avg_rating"
        case reviewCount = "review_count"
    }
}

/// Full public org profile returned by `/api/orgs/{org_id}`.
struct OrgProfile: Codable, Equatable {
    let id: String
    let name: String
    let description: String?
    let address: String?
    let iconURL: String?
    let bannerImageURL: String?
    let websiteURL: String?
    let yelpURL: String?
    let googleReviewsURL: String?
    let avgRating: Double?
    let serviceRadiusMiles: Double?
    let businessHours: [String: String]?
    let services: [Service]?
    let gallery: [GalleryImage]?

    struct Service: Codable, Equatable, Identifiable {
        let id: String
        let name: String
    }

    struct GalleryImage: Codable, Equatable, Identifiable {
        let id: String
        let imageURL: String?
        let caption: String?

        enum CodingKeys: String, CodingKey {
            case id, caption
            case imageURL = "image_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, address, services, gallery
        case iconURL = "icon_url"
        case bannerImageURL = "banner_image_url"
        case websiteURL = "website_url"
        case yelpURL = "yelp_url"
        case googleReviewsURL = "google_reviews_url"
        case avgRating = "avg_rating"
        case serviceRadiusMiles = "service_radius_miles"
        case businessHours = "business_hours"
    }
}
