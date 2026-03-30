import Foundation

/// The user-annotated room polygon from AR crosshair corner tracing.
/// Stored in the scan's metadata.json and used by the cloud processor
/// as the source of truth for room dimensions.
struct CornerAnnotation: Codable {
    /// 2D corner positions in AR world space, meters, CCW winding.
    /// Each element is [x, z] — Y is up in ARKit, so the floor polygon is in the XZ plane.
    let corners_xz: [[Float]]

    /// Per-corner Y height (ceiling height at each corner), meters.
    let corners_y: [Float]

    /// How the annotation was created.
    let annotation_method: String

    /// ISO 8601 timestamp of when the annotation was completed.
    let timestamp: String
}
