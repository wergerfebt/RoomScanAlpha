import Foundation
import simd

/// On-device coverage audit: checks whether captured frames cover walls, floor, and ceiling.
///
/// Projects a grid of sample points for each surface through every captured frame.
/// Returns coverage percentages per surface for diagnostic logging.
enum CoverageAudit {

    static let coverageThreshold: Float = 0.60
    private static let wallGrid = (u: 5, v: 4)
    private static let floorCeilGrid = (u: 5, v: 5)
    /// Typical US room height in meters — used to estimate floor Y from ceiling annotation.
    private static let estimatedRoomHeight: Float = 2.7

    // MARK: - Result Types

    struct SurfaceCoverage {
        let surfaceId: String
        let surfaceType: SurfaceType
        let coverage: Float
    }

    enum SurfaceType: String {
        case wall, floor, ceiling
    }

    struct Result {
        let surfaces: [SurfaceCoverage]
        let passed: Bool
        let worstSurface: SurfaceCoverage?
        let guidanceMessage: String
    }

    // MARK: - Internal Surface Representation

    private struct Surface {
        let surfaceId: String
        let surfaceType: SurfaceType
        let origin: SIMD3<Float>
        let uAxis: SIMD3<Float>
        let vAxis: SIMD3<Float>
        let widthM: Float
        let heightM: Float
    }

    // MARK: - Public API

    /// Run a coverage audit using annotation geometry and all captured frames.
    static func run(
        annotation: CornerAnnotation,
        frames: [CapturedFrame]
    ) -> Result {
        let floorY = estimateFloorY(annotation: annotation)
        let surfaces = buildSurfaces(from: annotation, floorY: floorY)

        // Precompute camera-from-world transforms
        struct CamData {
            let cfw: simd_float4x4
            let fx: Float; let fy: Float; let cx: Float; let cy: Float
            let w: Int; let h: Int
        }
        let cameraData: [CamData] = frames.map { frame in
            let k = frame.cameraIntrinsics
            return CamData(
                cfw: simd_inverse(frame.cameraTransform),
                fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                w: frame.imageWidth, h: frame.imageHeight
            )
        }

        var coverages: [SurfaceCoverage] = []

        for surface in surfaces {
            let grid = surface.surfaceType == .wall ? wallGrid : floorCeilGrid
            let totalPoints = grid.u * grid.v
            var coveredCount = 0

            for ui in 0..<grid.u {
                for vi in 0..<grid.v {
                    let uFrac = (Float(ui) + 0.5) / Float(grid.u)
                    let vFrac = (Float(vi) + 0.5) / Float(grid.v)
                    let uOffset = surface.uAxis * (uFrac * surface.widthM)
                    let vOffset = surface.vAxis * (vFrac * surface.heightM)
                    let worldPt = surface.origin + uOffset + vOffset

                    // Check if any frame sees this point
                    for cam in cameraData {
                        if projectInBounds(worldPt, cfw: cam.cfw,
                                           fx: cam.fx, fy: cam.fy, cx: cam.cx, cy: cam.cy,
                                           imageWidth: cam.w, imageHeight: cam.h) {
                            coveredCount += 1
                            break
                        }
                    }
                }
            }

            let cov = Float(coveredCount) / Float(max(totalPoints, 1))
            coverages.append(SurfaceCoverage(
                surfaceId: surface.surfaceId,
                surfaceType: surface.surfaceType,
                coverage: cov
            ))
        }

        let allPass = coverages.allSatisfy { $0.coverage >= coverageThreshold }
        let worst = coverages.min(by: { $0.coverage < $1.coverage })
        let message = worst.map { guidanceMessage(for: $0) } ?? ""

        print("[CoverageAudit] Results: \(coverages.map { "\($0.surfaceId)=\(Int($0.coverage*100))%" }.joined(separator: ", "))")
        print("[CoverageAudit] \(allPass ? "PASS" : "FAIL — \(message)")")

        return Result(surfaces: coverages, passed: allPass, worstSurface: worst, guidanceMessage: message)
    }

    // MARK: - Projection

    private static func projectInBounds(
        _ worldPoint: SIMD3<Float>,
        cfw: simd_float4x4,
        fx: Float, fy: Float, cx: Float, cy: Float,
        imageWidth: Int, imageHeight: Int
    ) -> Bool {
        let pt4 = SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1.0)
        let camPt = cfw * pt4
        let depth = -camPt.z
        guard depth > 0.01 else { return false }

        let px = fx * camPt.x / depth + cx
        let py = -fy * camPt.y / depth + cy

        return px >= 0 && px < Float(imageWidth) && py >= 0 && py < Float(imageHeight)
    }

    // MARK: - Surface Construction

    private static func estimateFloorY(annotation: CornerAnnotation) -> Float {
        let avgCeilingY = annotation.corners_y.reduce(0, +) / Float(max(annotation.corners_y.count, 1))
        return avgCeilingY - estimatedRoomHeight
    }

    private static func buildSurfaces(from annotation: CornerAnnotation, floorY: Float) -> [Surface] {
        let cornersXZ = annotation.corners_xz
        let cornersY = annotation.corners_y
        let n = cornersXZ.count
        guard n >= 3, cornersY.count >= n else { return [] }

        let avgCeilingY = cornersY.reduce(0, +) / Float(n)
        var surfaces: [Surface] = []

        // Walls
        for i in 0..<n {
            let j = (i + 1) % n
            let x0 = cornersXZ[i][0], z0 = cornersXZ[i][1]
            let x1 = cornersXZ[j][0], z1 = cornersXZ[j][1]

            let bl = SIMD3<Float>(x0, floorY, z0)
            let br = SIMD3<Float>(x1, floorY, z1)
            let uVec = br - bl
            let width = simd_length(uVec)
            guard width > 0.05 else { continue } // skip tiny segments

            let uAxis = uVec / width
            let vAxis = SIMD3<Float>(0, 1, 0)
            let avgHeight = ((cornersY[i] - floorY) + (cornersY[j] - floorY)) / 2

            surfaces.append(Surface(
                surfaceId: "wall_\(i)",
                surfaceType: .wall,
                origin: bl,
                uAxis: uAxis,
                vAxis: vAxis,
                widthM: width,
                heightM: avgHeight
            ))
        }

        // Floor & ceiling bounding box
        let xs = cornersXZ.map { $0[0] }
        let zs = cornersXZ.map { $0[1] }
        let minX = xs.min()!, maxX = xs.max()!
        let minZ = zs.min()!, maxZ = zs.max()!
        let floorW = maxX - minX
        let floorH = maxZ - minZ

        if floorW > 0.1 && floorH > 0.1 {
            surfaces.append(Surface(
                surfaceId: "floor",
                surfaceType: .floor,
                origin: SIMD3<Float>(minX, floorY, minZ),
                uAxis: SIMD3<Float>(1, 0, 0),
                vAxis: SIMD3<Float>(0, 0, 1),
                widthM: floorW,
                heightM: floorH
            ))
            surfaces.append(Surface(
                surfaceId: "ceiling",
                surfaceType: .ceiling,
                origin: SIMD3<Float>(minX, avgCeilingY, minZ),
                uAxis: SIMD3<Float>(1, 0, 0),
                vAxis: SIMD3<Float>(0, 0, 1),
                widthM: floorW,
                heightM: floorH
            ))
        }

        return surfaces
    }

    // MARK: - Guidance Messages

    private static func guidanceMessage(for surface: SurfaceCoverage) -> String {
        let pct = Int(surface.coverage * 100)
        switch surface.surfaceType {
        case .ceiling:
            return "Ceiling coverage is \(pct)%. Try pointing up toward the ceiling during your scan."
        case .floor:
            return "Floor coverage is \(pct)%. Try tilting down toward the floor during your scan."
        case .wall:
            return "\(surface.surfaceId.replacingOccurrences(of: "_", with: " ").capitalized) coverage is \(pct)%."
        }
    }
}
