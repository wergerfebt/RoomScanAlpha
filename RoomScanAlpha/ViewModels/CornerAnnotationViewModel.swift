import ARKit
import simd

/// Manages the corner annotation workflow: adding/removing corners,
/// polygon validation, winding normalization, and plane-intersection snap.
@Observable
final class CornerAnnotationViewModel {

    // MARK: - Corner State

    struct Corner {
        let x: Float
        let y: Float
        let z: Float
    }

    private(set) var corners: [Corner] = []
    private(set) var isClosed = false

    /// Area bounds for valid room polygons (square meters).
    static let minAreaM2: Float = 1.0
    static let maxAreaM2: Float = 500.0

    /// Snap radius: if raycast hit is within this distance of a plane intersection, snap to it.
    static let snapRadiusM: Float = 0.05

    var cornerCount: Int { corners.count }
    var canClose: Bool { corners.count >= 3 && !isClosed }
    var canDone: Bool { isClosed && isValid }

    // MARK: - Add / Undo / Close

    func addCorner(_ corner: Corner) {
        guard !isClosed else { return }
        corners.append(corner)
    }

    func undoLastCorner() {
        guard !isClosed, !corners.isEmpty else { return }
        corners.removeLast()
    }

    func closePolygon() {
        guard canClose else { return }
        isClosed = true
    }

    func reset() {
        corners.removeAll()
        isClosed = false
    }

    // MARK: - Polygon Area (XZ plane, in square meters)

    /// Shoelace formula area on the XZ plane. Returns positive value.
    var polygonAreaM2: Float {
        guard corners.count >= 3 else { return 0 }
        return abs(signedAreaXZ)
    }

    /// Signed area: positive = CCW, negative = CW (in XZ plane with Z pointing forward).
    private var signedAreaXZ: Float {
        var sum: Float = 0
        let n = corners.count
        for i in 0..<n {
            let j = (i + 1) % n
            sum += corners[i].x * corners[j].z - corners[j].x * corners[i].z
        }
        return sum / 2.0
    }

    /// True if winding is counter-clockwise in XZ plane.
    var isCCW: Bool { signedAreaXZ > 0 }

    // MARK: - Validation

    var isValid: Bool {
        guard corners.count >= 3 else { return false }
        let area = polygonAreaM2
        guard area >= Self.minAreaM2 && area <= Self.maxAreaM2 else { return false }
        guard !hasSelfIntersection else { return false }
        return true
    }

    /// Check if any non-adjacent edges of the polygon intersect.
    var hasSelfIntersection: Bool {
        let n = corners.count
        guard n >= 4 else { return false }

        for i in 0..<n {
            let a1 = SIMD2<Float>(corners[i].x, corners[i].z)
            let a2 = SIMD2<Float>(corners[(i + 1) % n].x, corners[(i + 1) % n].z)
            let jStart = i + 2
            guard jStart < n else { continue }
            for j in jStart..<n {
                // Skip adjacent edges (they share a vertex)
                if j == (i + n - 1) % n { continue }
                let b1 = SIMD2<Float>(corners[j].x, corners[j].z)
                let b2 = SIMD2<Float>(corners[(j + 1) % n].x, corners[(j + 1) % n].z)
                if Self.segmentsIntersect(a1, a2, b1, b2) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Winding Normalization

    /// Return corners in CCW order (reverses if currently CW).
    var cornersNormalizedCCW: [Corner] {
        if isCCW { return corners }
        return corners.reversed()
    }

    // MARK: - Export

    /// Build the Codable CornerAnnotation for metadata.json.
    /// Returns nil if annotation was skipped or polygon is invalid.
    var cornerAnnotation: CornerAnnotation? {
        guard isClosed, corners.count >= 3 else { return nil }

        let normalized = cornersNormalizedCCW
        let xz = normalized.map { [$0.x, $0.z] }
        let y = normalized.map { $0.y }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return CornerAnnotation(
            corners_xz: xz,
            corners_y: y,
            annotation_method: "ar_crosshair_snap",
            timestamp: formatter.string(from: Date())
        )
    }

    // MARK: - Plane-Intersection Snap

    /// Attempt to snap a raycast hit point to a nearby plane intersection (wall-ceiling junction).
    /// Falls back to the original hit point if no snap candidate is found.
    static func snapToPlaneIntersection(
        hitPoint: SIMD3<Float>,
        session: ARSession,
        snapRadius: Float = snapRadiusM
    ) -> SIMD3<Float> {
        guard let frame = session.currentFrame else { return hitPoint }

        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }

        // Collect nearby classified faces within snap radius
        var wallVertices: [SIMD3<Float>] = []
        var ceilingVertices: [SIMD3<Float>] = []

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let transform = anchor.transform

            for faceIndex in 0..<geometry.faces.count {
                let classification = geometry.classificationOf(faceWithIndex: faceIndex)
                guard classification == .wall || classification == .ceiling else { continue }

                // Get face vertices in world space
                let vertexIndices = geometry.faceIndices(at: faceIndex)

                for idx in vertexIndices {
                    let localPos = geometry.vertex(at: idx)
                    let worldPos = transform * SIMD4<Float>(localPos, 1)
                    let worldPos3 = SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z)

                    if simd_distance(worldPos3, hitPoint) <= snapRadius * 3 {
                        if classification == .wall {
                            wallVertices.append(worldPos3)
                        } else {
                            ceilingVertices.append(worldPos3)
                        }
                    }
                }
            }
        }

        // Need vertices from both surfaces to compute intersection
        guard wallVertices.count >= 3, ceilingVertices.count >= 3 else {
            return hitPoint
        }

        // Fit planes via least-squares (simplified RANSAC for speed)
        guard let wallPlane = fitPlane(points: wallVertices),
              let ceilingPlane = fitPlane(points: ceilingVertices) else {
            return hitPoint
        }

        // Compute intersection line of two planes
        guard let (linePoint, lineDir) = planeIntersectionLine(wallPlane, ceilingPlane) else {
            return hitPoint
        }

        // Project hit point onto the intersection line
        let projected = linePoint + simd_dot(hitPoint - linePoint, lineDir) * lineDir
        let snapDist = simd_distance(projected, hitPoint)

        if snapDist <= snapRadius {
            return projected
        }
        return hitPoint
    }

    // MARK: - Geometry Helpers

    /// Fit a plane (normal, d) to a set of 3D points using the mean + covariance method.
    /// Returns (normal, d) where normal · point + d ≈ 0 for points on the plane.
    static func fitPlane(points: [SIMD3<Float>]) -> (normal: SIMD3<Float>, d: Float)? {
        guard points.count >= 3 else { return nil }

        // Compute centroid
        var centroid = SIMD3<Float>(0, 0, 0)
        for p in points { centroid += p }
        centroid /= Float(points.count)

        // Compute covariance matrix elements
        var xx: Float = 0, xy: Float = 0, xz: Float = 0
        var yy: Float = 0, yz: Float = 0, zz: Float = 0

        for p in points {
            let d = p - centroid
            xx += d.x * d.x
            xy += d.x * d.y
            xz += d.x * d.z
            yy += d.y * d.y
            yz += d.y * d.z
            zz += d.z * d.z
        }

        // Find the eigenvector with smallest eigenvalue via the cross-product method
        // for 3x3 symmetric matrices. Test all three possible normal directions.
        let detX = yy * zz - yz * yz
        let detY = xx * zz - xz * xz
        let detZ = xx * yy - xy * xy

        let maxDet = max(detX, detY, detZ)
        guard maxDet > 1e-10 else { return nil }

        var normal: SIMD3<Float>
        if maxDet == detX {
            normal = SIMD3<Float>(detX, xz * yz - xy * zz, xy * yz - xz * yy)
        } else if maxDet == detY {
            normal = SIMD3<Float>(xz * yz - xy * zz, detY, xy * xz - yz * xx)
        } else {
            normal = SIMD3<Float>(xy * yz - xz * yy, xy * xz - yz * xx, detZ)
        }

        let len = simd_length(normal)
        guard len > 1e-10 else { return nil }
        normal /= len

        let d = -simd_dot(normal, centroid)
        return (normal, d)
    }

    /// Compute the intersection line of two planes.
    /// Returns a point on the line and the line direction.
    static func planeIntersectionLine(
        _ p1: (normal: SIMD3<Float>, d: Float),
        _ p2: (normal: SIMD3<Float>, d: Float)
    ) -> (point: SIMD3<Float>, direction: SIMD3<Float>)? {
        let dir = simd_cross(p1.normal, p2.normal)
        let dirLen = simd_length(dir)
        guard dirLen > 1e-6 else { return nil }  // Planes are parallel
        let normalizedDir = dir / dirLen

        // Find a point on the line by solving the system of plane equations
        // n1·P = -d1, n2·P = -d2
        // Use the axis where dir has largest component to avoid division by near-zero
        let absDir = SIMD3<Float>(abs(dir.x), abs(dir.y), abs(dir.z))
        var point = SIMD3<Float>(0, 0, 0)

        if absDir.z >= absDir.x && absDir.z >= absDir.y {
            // Solve for x, y (set z = 0)
            let det = p1.normal.x * p2.normal.y - p1.normal.y * p2.normal.x
            guard abs(det) > 1e-6 else { return nil }
            point.x = (-p1.d * p2.normal.y + p2.d * p1.normal.y) / det
            point.y = (-p2.d * p1.normal.x + p1.d * p2.normal.x) / det
        } else if absDir.y >= absDir.x {
            // Solve for x, z (set y = 0)
            let det = p1.normal.x * p2.normal.z - p1.normal.z * p2.normal.x
            guard abs(det) > 1e-6 else { return nil }
            point.x = (-p1.d * p2.normal.z + p2.d * p1.normal.z) / det
            point.z = (-p2.d * p1.normal.x + p1.d * p2.normal.x) / det
        } else {
            // Solve for y, z (set x = 0)
            let det = p1.normal.y * p2.normal.z - p1.normal.z * p2.normal.y
            guard abs(det) > 1e-6 else { return nil }
            point.y = (-p1.d * p2.normal.z + p2.d * p1.normal.z) / det
            point.z = (-p2.d * p1.normal.y + p1.d * p2.normal.y) / det
        }

        return (point, normalizedDir)
    }

    /// Test whether two 2D line segments intersect (proper intersection, not touching at endpoints).
    static func segmentsIntersect(
        _ a1: SIMD2<Float>, _ a2: SIMD2<Float>,
        _ b1: SIMD2<Float>, _ b2: SIMD2<Float>
    ) -> Bool {
        let d1 = a2 - a1
        let d2 = b2 - b1
        let cross = d1.x * d2.y - d1.y * d2.x

        guard abs(cross) > 1e-10 else { return false }  // Parallel

        let d3 = b1 - a1
        let t = (d3.x * d2.y - d3.y * d2.x) / cross
        let u = (d3.x * d1.y - d3.y * d1.x) / cross

        // Strict interior intersection (not at endpoints)
        return t > 0.001 && t < 0.999 && u > 0.001 && u < 0.999
    }
}
