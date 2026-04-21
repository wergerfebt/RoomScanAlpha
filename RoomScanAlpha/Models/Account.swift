import Foundation

/// Unified account returned by `/api/account`. May be a homeowner
/// or a contractor org member (when `org` is non-nil).
struct Account: Codable, Equatable {
    let id: String
    let email: String
    let name: String?
    let accountType: String?
    let iconURL: String?
    let org: OrgMembership?

    struct OrgMembership: Codable, Equatable {
        let id: String
        let name: String
        let role: String
        let iconURL: String?

        enum CodingKeys: String, CodingKey {
            case id, name, role
            case iconURL = "icon_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, email, name, org
        case accountType = "account_type"
        case iconURL = "icon_url"
    }
}
