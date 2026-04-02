import Foundation

/// Scope of work for a scanned room — a flat list of selected work item tags + free-text notes.
struct RoomScope: Codable, Equatable {
    var items: [String] = []
    var notes: String = ""

    enum CodingKeys: String, CodingKey {
        case items, notes
    }
}

/// Catalog of scope items grouped by room type applicability.
enum ScopeItemCatalog {

    struct Item: Identifiable {
        let id: String       // e.g. "new_paint"
        let label: String    // e.g. "New Paint"
    }

    /// Items shown for all room types.
    static let general: [Item] = [
        Item(id: "new_paint", label: "New Paint"),
        Item(id: "new_flooring", label: "New Flooring"),
        Item(id: "new_light_fixtures", label: "New Light Fixtures"),
        Item(id: "new_outlets_switches", label: "New Outlets/Switches"),
        Item(id: "new_baseboard", label: "New Baseboard"),
        Item(id: "new_blinds_curtains", label: "New Blinds/Curtains"),
        Item(id: "drywall_patches", label: "Drywall Patches"),
        Item(id: "crown_molding", label: "Crown Molding"),
        Item(id: "contents_removal", label: "Contents Removal"),
    ]

    /// Additional items for kitchens.
    static let kitchen: [Item] = [
        Item(id: "new_cabinets", label: "New Cabinets"),
        Item(id: "new_countertop", label: "New Countertop"),
        Item(id: "new_backsplash", label: "New Backsplash"),
        Item(id: "new_sink_faucet", label: "New Sink/Faucet"),
        Item(id: "new_appliances", label: "New Appliances"),
        Item(id: "garbage_disposal", label: "Garbage Disposal"),
    ]

    /// Additional items for bathrooms.
    static let bathroom: [Item] = [
        Item(id: "new_shower_tub", label: "New Shower/Tub"),
        Item(id: "new_toilet", label: "New Toilet"),
        Item(id: "new_vanity", label: "New Vanity"),
        Item(id: "new_mirror", label: "New Mirror"),
        Item(id: "new_exhaust_fan", label: "New Exhaust Fan"),
    ]

    /// Return all applicable items for a given room label.
    static func items(for roomLabel: String) -> [Item] {
        var result = general
        let lower = roomLabel.lowercased()
        if lower.contains("kitchen") {
            result += kitchen
        }
        if lower.contains("bath") {
            result += bathroom
        }
        return result
    }
}
