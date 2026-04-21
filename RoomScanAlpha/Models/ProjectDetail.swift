import Foundation

/// A single scanned room returned from /api/rfqs/{id}/contractor-view.
struct ProjectRoom: Identifiable, Codable, Equatable {
    let scanId: String
    let roomLabel: String?
    let floorAreaSqft: Double?
    let wallAreaSqft: Double?
    let ceilingHeightFt: Double?
    let perimeterLinearFt: Double?
    let roomPolygonFt: [[Double]]?
    let scanStatus: String
    let hasSplat: Bool?
    let scope: RoomScopeSummary?

    var id: String { scanId }
    var displayLabel: String { roomLabel ?? "Room" }

    enum CodingKeys: String, CodingKey {
        case scanId = "scan_id"
        case roomLabel = "room_label"
        case floorAreaSqft = "floor_area_sqft"
        case wallAreaSqft = "wall_area_sqft"
        case ceilingHeightFt = "ceiling_height_ft"
        case perimeterLinearFt = "perimeter_linear_ft"
        case roomPolygonFt = "room_polygon_ft"
        case scanStatus = "scan_status"
        case hasSplat = "has_splat"
        case scope
    }
}

/// Scope items + notes for a single room (matches the `scope` JSONB column).
struct RoomScopeSummary: Codable, Equatable {
    let items: [String]?
    let notes: String?
}

/// Full project view returned by /api/rfqs/{id}/contractor-view.
struct ProjectDetail: Codable, Equatable {
    let rfqId: String
    let title: String?
    let address: String?
    let jobDescription: String?
    let projectScope: String?
    let rooms: [ProjectRoom]

    var displayTitle: String { title ?? "Untitled Project" }

    var totalFloorSqft: Double {
        rooms.reduce(0) { $0 + ($1.floorAreaSqft ?? 0) }
    }

    var averageCeilingFt: Double? {
        let values = rooms.compactMap(\.ceilingHeightFt)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    enum CodingKeys: String, CodingKey {
        case rfqId = "rfq_id"
        case title, address, rooms
        case jobDescription = "job_description"
        case projectScope = "project_scope"
    }
}
