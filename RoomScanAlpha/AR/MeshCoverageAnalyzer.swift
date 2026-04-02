// Checks which mesh faces have at least one viable camera candidate for texturing.
// A camera is viable if the face centroid projects into its image at a usable viewing angle.
// Matches OpenMVS TextureMesh criteria: in-bounds, viewing angle, distance.
//
// Mesh data is extracted into plain arrays on the main thread to avoid ARFrame retention.

import ARKit
import simd

struct MeshCoverageAnalyzer {

    struct Result {
        /// Anchor UUID → set of uncovered face indices within that anchor.
        let uncoveredFaces: [UUID: Set<Int>]
        /// 0.0–1.0 fraction of analyzed faces that have at least one viable camera.
        let coverageRatio: Float
        /// Total faces analyzed.
        let totalFaces: Int
        /// Total uncovered faces.
        let uncoveredCount: Int
    }

    /// Analyze every Nth face for speed. 2 = every other face.
    private static let faceStride = 2

    // MARK: - Viability thresholds (matching OpenMVS behavior)

    /// Minimum dot(face_normal, cam_direction) for walls.
    private static let minAngleWall: Float = 0.1       // ~84°
    /// Minimum dot(face_normal, cam_direction) for floor/ceiling (viewed obliquely).
    private static let minAngleFloorCeil: Float = 0.02  // ~89°
    /// Minimum distance from camera to face (meters).
    private static let minDistance: Float = 0.2
    /// Maximum distance from camera to face (meters).
    private static let maxDistance: Float = 5.0
    /// Margin inside image bounds (pixels) — ignore extreme edges where distortion is worst.
    private static let imageMargin: Float = 50.0

    // MARK: - Snapshot (plain value types, no ARKit references)

    private struct FaceData {
        let anchorIndex: Int
        let faceIndex: Int
        let centroid: SIMD3<Float>
        let normal: SIMD3<Float>
        let isFloorOrCeiling: Bool
    }

    private struct CameraData {
        let position: SIMD3<Float>
        let cameraFromWorld: simd_float4x4
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
        let imageWidth: Float
        let imageHeight: Float
    }

    private struct Snapshot {
        let faces: [FaceData]
        let anchorIDs: [UUID]  // index → anchor UUID
        let totalFaces: Int
    }

    // MARK: - Public API

    /// Run coverage analysis. Extracts mesh data on the calling thread (main),
    /// then processes on a background queue to avoid blocking.
    static func analyze(
        meshAnchors: [ARMeshAnchor],
        frames: [CapturedFrame],
        completion: @escaping (Result) -> Void
    ) {
        // Extract on main thread — releases ARMeshAnchor references immediately
        let snapshot = extractSnapshot(from: meshAnchors)
        let cameras = extractCameras(from: frames)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = checkCoverage(snapshot: snapshot, cameras: cameras)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    // MARK: - Data Extraction (main thread)

    private static func extractSnapshot(from meshAnchors: [ARMeshAnchor]) -> Snapshot {
        var faces: [FaceData] = []
        var anchorIDs: [UUID] = []
        var totalFaces = 0

        for (anchorIdx, anchor) in meshAnchors.enumerated() {
            let geo = anchor.geometry
            let faceCount = geo.faces.count
            let worldTransform = anchor.transform
            anchorIDs.append(anchor.identifier)
            totalFaces += faceCount

            for faceIdx in stride(from: 0, to: faceCount, by: faceStride) {
                let indices = geo.faceIndices(at: faceIdx)
                let v0 = geo.vertex(at: indices[0])
                let v1 = geo.vertex(at: indices[1])
                let v2 = geo.vertex(at: indices[2])

                // Transform to world space
                let w0 = worldTransform * SIMD4<Float>(v0.x, v0.y, v0.z, 1)
                let w1 = worldTransform * SIMD4<Float>(v1.x, v1.y, v1.z, 1)
                let w2 = worldTransform * SIMD4<Float>(v2.x, v2.y, v2.z, 1)

                let centroid = SIMD3<Float>(
                    (w0.x + w1.x + w2.x) / 3,
                    (w0.y + w1.y + w2.y) / 3,
                    (w0.z + w1.z + w2.z) / 3
                )

                // World-space normal
                let e1 = SIMD3<Float>(w1.x - w0.x, w1.y - w0.y, w1.z - w0.z)
                let e2 = SIMD3<Float>(w2.x - w0.x, w2.y - w0.y, w2.z - w0.z)
                let cross = simd_cross(e1, e2)
                let len = simd_length(cross)
                let normal = len > 1e-8 ? cross / len : SIMD3<Float>(0, 1, 0)

                // Classification-based threshold
                let classification = geo.classificationOf(faceWithIndex: faceIdx)
                let isFloorOrCeiling = classification == .floor || classification == .ceiling

                faces.append(FaceData(
                    anchorIndex: anchorIdx,
                    faceIndex: faceIdx,
                    centroid: centroid,
                    normal: normal,
                    isFloorOrCeiling: isFloorOrCeiling
                ))
            }
        }

        return Snapshot(faces: faces, anchorIDs: anchorIDs, totalFaces: totalFaces)
    }

    private static func extractCameras(from frames: [CapturedFrame]) -> [CameraData] {
        frames.map { frame in
            let k = frame.cameraIntrinsics
            let pos = frame.cameraTransform.columns.3
            return CameraData(
                position: SIMD3<Float>(pos.x, pos.y, pos.z),
                cameraFromWorld: simd_inverse(frame.cameraTransform),
                fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                imageWidth: Float(frame.imageWidth),
                imageHeight: Float(frame.imageHeight)
            )
        }
    }

    // MARK: - Coverage Check (background thread)

    private static func checkCoverage(snapshot: Snapshot, cameras: [CameraData]) -> Result {
        var uncoveredByAnchor: [Int: Set<Int>] = [:]  // anchorIndex → face indices
        var uncoveredCount = 0

        for face in snapshot.faces {
            let angleThreshold = face.isFloorOrCeiling ? minAngleFloorCeil : minAngleWall
            var hasCandidate = false

            for cam in cameras {
                if isViableCandidate(face: face, camera: cam, angleThreshold: angleThreshold) {
                    hasCandidate = true
                    break
                }
            }

            if !hasCandidate {
                uncoveredByAnchor[face.anchorIndex, default: []].insert(face.faceIndex)
                uncoveredCount += 1
            }
        }

        let totalAnalyzed = snapshot.faces.count
        let ratio: Float = totalAnalyzed > 0 ? Float(totalAnalyzed - uncoveredCount) / Float(totalAnalyzed) : 1.0

        // Convert anchorIndex keys to UUIDs
        var result: [UUID: Set<Int>] = [:]
        for (anchorIdx, faceSet) in uncoveredByAnchor {
            if anchorIdx < snapshot.anchorIDs.count {
                result[snapshot.anchorIDs[anchorIdx]] = faceSet
            }
        }

        print("[CoverageAnalyzer] \(totalAnalyzed) faces checked, \(uncoveredCount) uncovered (\(Int((1 - ratio) * 100))% gaps), \(cameras.count) cameras")

        return Result(
            uncoveredFaces: result,
            coverageRatio: ratio,
            totalFaces: totalAnalyzed,
            uncoveredCount: uncoveredCount
        )
    }

    /// Check if a camera is a viable texture candidate for a face.
    private static func isViableCandidate(face: FaceData, camera: CameraData, angleThreshold: Float) -> Bool {
        // 1. Distance check
        let toFace = face.centroid - camera.position
        let distance = simd_length(toFace)
        guard distance >= minDistance && distance <= maxDistance else { return false }

        // 2. Viewing angle check: dot(face_normal, direction_to_camera)
        let toCam = camera.position - face.centroid
        let toCamNorm = toCam / distance
        let angleDot = simd_dot(face.normal, toCamNorm)
        guard angleDot > angleThreshold else { return false }

        // 3. Projection bounds check
        let worldPt = SIMD4<Float>(face.centroid.x, face.centroid.y, face.centroid.z, 1.0)
        let camPt = camera.cameraFromWorld * worldPt
        let depth = -camPt.z
        guard depth > 0.1 else { return false }

        let px = camera.fx * camPt.x / depth + camera.cx
        let py = -camera.fy * camPt.y / depth + camera.cy

        return px >= imageMargin && px < (camera.imageWidth - imageMargin)
            && py >= imageMargin && py < (camera.imageHeight - imageMargin)
    }
}
