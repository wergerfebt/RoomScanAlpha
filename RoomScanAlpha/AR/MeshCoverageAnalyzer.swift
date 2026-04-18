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
        /// 0.0–1.0 fraction of the 6 room-shell directions that the mesh extends
        /// meaningfully beyond the camera path — captures "missing walls" that
        /// `coverageRatio` cannot see because the wall simply was never scanned.
        let enclosureCompleteness: Float
        /// Per-direction enclosure scores: [−X, +X, floor (−Y), ceiling (+Y), −Z, +Z].
        /// Each entry is 0 (missing) or 1 (captured). The index matches
        /// `EnclosureDirection.allCases`.
        let enclosureDirections: [EnclosureDirection: Bool]
        /// User walked far enough that enclosure analysis is meaningful. When false,
        /// `enclosureCompleteness` is 0 — callers should coach the user to walk more
        /// rather than report a missing-wall warning.
        let hasEnoughCameraMotion: Bool
        /// Mesh holes detected by ray-casting from the scan-space centroid.
        /// Each entry is a world-space point on the bounding box where a ray
        /// escaped through a gap — render as red markers in AR so the user
        /// can walk toward them.
        let holes: [HoleSample]
    }

    enum EnclosureDirection: String, CaseIterable {
        case leftWall = "left wall"      // −X
        case rightWall = "right wall"    // +X
        case floor = "floor"              // −Y
        case ceiling = "ceiling"          // +Y
        case frontWall = "front wall"    // −Z
        case backWall = "back wall"      // +Z
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
        /// World-space vertex samples used to build the voxel occupancy grid for
        /// hole detection. 3 vertices per sampled face (same `faceStride` as `faces`).
        let vertexPositions: [SIMD3<Float>]
    }

    /// A mesh hole — a ray-cast escape point on the bounding box surface.
    /// Rendered as a red marker in the coverage review AR overlay.
    struct HoleSample: Equatable {
        let worldPosition: SIMD3<Float>
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

    /// Run coverage analysis using lightweight pose samples (no keyframe image data).
    /// Cheaper than the `frames:` variant — used for the inline on-device coverage
    /// review that runs between scan-stop and annotation.
    static func analyze(
        meshAnchors: [ARMeshAnchor],
        poseSamples: [CameraPoseSample],
        completion: @escaping (Result) -> Void
    ) {
        let snapshot = extractSnapshot(from: meshAnchors)
        let cameras = extractCameras(from: poseSamples)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = checkCoverage(snapshot: snapshot, cameras: cameras)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func extractCameras(from samples: [CameraPoseSample]) -> [CameraData] {
        samples.map { sample in
            let k = sample.intrinsics
            let pos = sample.transform.columns.3
            return CameraData(
                position: SIMD3<Float>(pos.x, pos.y, pos.z),
                cameraFromWorld: simd_inverse(sample.transform),
                fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                imageWidth: Float(sample.imageWidth),
                imageHeight: Float(sample.imageHeight)
            )
        }
    }

    // MARK: - Data Extraction (main thread)

    private static func extractSnapshot(from meshAnchors: [ARMeshAnchor]) -> Snapshot {
        var faces: [FaceData] = []
        var anchorIDs: [UUID] = []
        var totalFaces = 0
        var vertexPositions: [SIMD3<Float>] = []

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

                let p0 = SIMD3<Float>(w0.x, w0.y, w0.z)
                let p1 = SIMD3<Float>(w1.x, w1.y, w1.z)
                let p2 = SIMD3<Float>(w2.x, w2.y, w2.z)

                let centroid = (p0 + p1 + p2) / 3

                // World-space normal
                let e1 = p1 - p0
                let e2 = p2 - p0
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

                vertexPositions.append(p0)
                vertexPositions.append(p1)
                vertexPositions.append(p2)
            }
        }

        return Snapshot(
            faces: faces,
            anchorIDs: anchorIDs,
            totalFaces: totalFaces,
            vertexPositions: vertexPositions
        )
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

        let enclosure = computeEnclosure(snapshot: snapshot, cameras: cameras)
        let holes = detectHoles(snapshot: snapshot, cameras: cameras)

        print("[CoverageAnalyzer] \(totalAnalyzed) faces checked, \(uncoveredCount) uncovered (\(Int((1 - ratio) * 100))% gaps), \(cameras.count) cameras, enclosure \(Int(enclosure.completeness * 100))%, holes=\(holes.count)")

        return Result(
            uncoveredFaces: result,
            coverageRatio: ratio,
            totalFaces: totalAnalyzed,
            uncoveredCount: uncoveredCount,
            enclosureCompleteness: enclosure.completeness,
            enclosureDirections: enclosure.directions,
            hasEnoughCameraMotion: enclosure.hasMotion,
            holes: holes
        )
    }

    // MARK: - Enclosure Completeness

    /// Minimum camera-path extent (meters) in X AND Z before we trust the
    /// enclosure metric. Under this, the user hasn't walked enough.
    private static let minCameraMotionExtent: Float = 0.8
    /// Mesh must extend at least this far beyond the camera bbox edge in a
    /// given direction for that direction to count as "enclosed."
    private static let enclosureMargin: Float = 0.3

    /// How much the mesh extends beyond the camera path on each of the 6 room
    /// axes. A missing wall shows up as a direction the mesh doesn't reach.
    private static func computeEnclosure(
        snapshot: Snapshot,
        cameras: [CameraData]
    ) -> (completeness: Float, directions: [EnclosureDirection: Bool], hasMotion: Bool) {
        let empty: [EnclosureDirection: Bool] = Dictionary(
            uniqueKeysWithValues: EnclosureDirection.allCases.map { ($0, false) }
        )

        guard !cameras.isEmpty, !snapshot.faces.isEmpty else {
            return (0, empty, false)
        }

        // Camera path AABB.
        var camMin = cameras[0].position
        var camMax = cameras[0].position
        for cam in cameras {
            camMin = simd_min(camMin, cam.position)
            camMax = simd_max(camMax, cam.position)
        }
        let camExtentX = camMax.x - camMin.x
        let camExtentZ = camMax.z - camMin.z
        let hasMotion = camExtentX >= minCameraMotionExtent && camExtentZ >= minCameraMotionExtent

        guard hasMotion else { return (0, empty, false) }

        // Mesh AABB from face centroids.
        var meshMin = snapshot.faces[0].centroid
        var meshMax = snapshot.faces[0].centroid
        for face in snapshot.faces {
            meshMin = simd_min(meshMin, face.centroid)
            meshMax = simd_max(meshMax, face.centroid)
        }

        var directions: [EnclosureDirection: Bool] = [:]
        directions[.leftWall]   = (camMin.x - meshMin.x) >= enclosureMargin
        directions[.rightWall]  = (meshMax.x - camMax.x) >= enclosureMargin
        directions[.floor]      = (camMin.y - meshMin.y) >= enclosureMargin
        directions[.ceiling]    = (meshMax.y - camMax.y) >= enclosureMargin
        directions[.frontWall]  = (camMin.z - meshMin.z) >= enclosureMargin
        directions[.backWall]   = (meshMax.z - camMax.z) >= enclosureMargin

        let capturedCount = directions.values.filter { $0 }.count
        let completeness = Float(capturedCount) / Float(EnclosureDirection.allCases.count)
        return (completeness, directions, true)
    }

    // MARK: - Hole Detection (voxel ray-cast from scan centroid)

    /// Fibonacci-sphere rays cast from the scan centroid. Higher = finer hole
    /// resolution; 500 hits every ~1.2° of solid angle, which is dense enough
    /// to surface a fist-sized hole from 3 m away.
    private static let holeRayCount: Int = 500
    /// Voxel resolution for the occupancy grid. 20 cm resolves typical gaps
    /// (e.g., missing ceiling patches) without blowing memory: a 6×3×6 m
    /// room = 30×15×30 = 13.5 k cells.
    private static let holeVoxelSize: Float = 0.20
    /// Bounding box padding beyond the mesh extent — lets rays exit cleanly.
    private static let holeBboxPad: Float = 0.15

    /// Cast `holeRayCount` rays from the scan centroid. Rays that fail to hit
    /// any occupied voxel before leaving the bounding box escape through a
    /// hole; record the bbox exit point so the UI can render a red AR marker.
    private static func detectHoles(snapshot: Snapshot, cameras: [CameraData]) -> [HoleSample] {
        guard !cameras.isEmpty, !snapshot.vertexPositions.isEmpty else { return [] }

        // Mesh AABB + padding
        var minV = snapshot.vertexPositions[0]
        var maxV = snapshot.vertexPositions[0]
        for v in snapshot.vertexPositions {
            minV = simd_min(minV, v)
            maxV = simd_max(maxV, v)
        }
        let pad = SIMD3<Float>(repeating: holeBboxPad)
        let bmin = minV - pad
        let bmax = maxV + pad
        let extent = bmax - bmin

        let gx = max(1, Int(ceil(extent.x / holeVoxelSize)))
        let gy = max(1, Int(ceil(extent.y / holeVoxelSize)))
        let gz = max(1, Int(ceil(extent.z / holeVoxelSize)))
        let totalCells = gx * gy * gz
        guard totalCells > 0, totalCells < 2_000_000 else { return [] }

        var grid = [Bool](repeating: false, count: totalCells)
        @inline(__always) func idx(_ ix: Int, _ iy: Int, _ iz: Int) -> Int {
            ix + gx * (iy + gy * iz)
        }

        for v in snapshot.vertexPositions {
            let rx = (v.x - bmin.x) / holeVoxelSize
            let ry = (v.y - bmin.y) / holeVoxelSize
            let rz = (v.z - bmin.z) / holeVoxelSize
            guard rx >= 0, ry >= 0, rz >= 0 else { continue }
            let ix = min(gx - 1, Int(rx))
            let iy = min(gy - 1, Int(ry))
            let iz = min(gz - 1, Int(rz))
            grid[idx(ix, iy, iz)] = true
        }

        // Ray origin: camera-path centroid, clamped inside the bbox.
        var origin = SIMD3<Float>(0, 0, 0)
        for cam in cameras { origin += cam.position }
        origin /= Float(cameras.count)
        origin = simd_clamp(
            origin,
            bmin + SIMD3(repeating: holeVoxelSize),
            bmax - SIMD3(repeating: holeVoxelSize)
        )

        let goldenAngle = Float.pi * (sqrt(5.0) - 1.0)
        var holes: [HoleSample] = []

        for i in 0..<holeRayCount {
            let fi = Float(i)
            let y = 1 - (fi / Float(holeRayCount - 1)) * 2
            let r = sqrt(max(0, 1 - y * y))
            let theta = goldenAngle * fi
            let dir = SIMD3<Float>(cos(theta) * r, y, sin(theta) * r)

            if !rayHitsOccupiedVoxel(
                origin: origin,
                direction: dir,
                grid: grid, gx: gx, gy: gy, gz: gz,
                bmin: bmin, voxelSize: holeVoxelSize
            ) {
                let exit = rayBboxExit(origin: origin, direction: dir, bmin: bmin, bmax: bmax)
                holes.append(HoleSample(worldPosition: exit))
            }
        }

        return holes
    }

    /// Amanatides-Woo voxel traversal. Returns true if any voxel along the ray
    /// from `origin` in `direction` is occupied, before leaving the grid.
    private static func rayHitsOccupiedVoxel(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        grid: [Bool], gx: Int, gy: Int, gz: Int,
        bmin: SIMD3<Float>, voxelSize: Float
    ) -> Bool {
        let rel = origin - bmin
        var ix = Int(rel.x / voxelSize)
        var iy = Int(rel.y / voxelSize)
        var iz = Int(rel.z / voxelSize)
        if ix < 0 { ix = 0 } else if ix >= gx { ix = gx - 1 }
        if iy < 0 { iy = 0 } else if iy >= gy { iy = gy - 1 }
        if iz < 0 { iz = 0 } else if iz >= gz { iz = gz - 1 }

        let sx = direction.x > 0 ? 1 : (direction.x < 0 ? -1 : 0)
        let sy = direction.y > 0 ? 1 : (direction.y < 0 ? -1 : 0)
        let sz = direction.z > 0 ? 1 : (direction.z < 0 ? -1 : 0)

        let inf = Float.greatestFiniteMagnitude
        let nextBoundary: (Float, Int, Int) -> Float = { rel, i, step in
            let edge = Float(i + (step > 0 ? 1 : 0)) * voxelSize
            return edge - rel
        }

        var tMaxX = sx == 0 ? inf : nextBoundary(rel.x, ix, sx) / direction.x
        var tMaxY = sy == 0 ? inf : nextBoundary(rel.y, iy, sy) / direction.y
        var tMaxZ = sz == 0 ? inf : nextBoundary(rel.z, iz, sz) / direction.z
        let tDeltaX = sx == 0 ? inf : Float(sx) * voxelSize / direction.x
        let tDeltaY = sy == 0 ? inf : Float(sy) * voxelSize / direction.y
        let tDeltaZ = sz == 0 ? inf : Float(sz) * voxelSize / direction.z

        let maxSteps = gx + gy + gz + 2
        var step = 0
        while step < maxSteps {
            if grid[ix + gx * (iy + gy * iz)] {
                return true
            }
            if tMaxX < tMaxY {
                if tMaxX < tMaxZ {
                    ix += sx; if ix < 0 || ix >= gx { return false }
                    tMaxX += tDeltaX
                } else {
                    iz += sz; if iz < 0 || iz >= gz { return false }
                    tMaxZ += tDeltaZ
                }
            } else {
                if tMaxY < tMaxZ {
                    iy += sy; if iy < 0 || iy >= gy { return false }
                    tMaxY += tDeltaY
                } else {
                    iz += sz; if iz < 0 || iz >= gz { return false }
                    tMaxZ += tDeltaZ
                }
            }
            step += 1
        }
        return false
    }

    /// Intersect a ray with an AABB, returning the far-side exit point.
    private static func rayBboxExit(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        bmin: SIMD3<Float>,
        bmax: SIMD3<Float>
    ) -> SIMD3<Float> {
        let inv = SIMD3<Float>(
            direction.x == 0 ? Float.greatestFiniteMagnitude : 1 / direction.x,
            direction.y == 0 ? Float.greatestFiniteMagnitude : 1 / direction.y,
            direction.z == 0 ? Float.greatestFiniteMagnitude : 1 / direction.z
        )
        let t1 = (bmin - origin) * inv
        let t2 = (bmax - origin) * inv
        let tFar = simd_min(simd_max(t1, t2), SIMD3<Float>(repeating: 1e9))
        let t = min(tFar.x, min(tFar.y, tFar.z))
        return origin + direction * max(0, t)
    }

    // MARK: - Overlay Adapter

    /// Convert an analyzer `Result` into world-space triangle vertices matching
    /// the shape `GapRescanView.buildOverlayMesh` expects. Must run on the main
    /// thread while `meshAnchors` are still live (ARMeshAnchor retention rules).
    static func buildUncoveredFaces(
        result: Result,
        meshAnchors: [ARMeshAnchor]
    ) -> [CloudUploader.UncoveredFace] {
        let anchorsByID = Dictionary(
            uniqueKeysWithValues: meshAnchors.map { ($0.identifier, $0) }
        )
        var faces: [CloudUploader.UncoveredFace] = []
        faces.reserveCapacity(result.uncoveredCount)

        for (uuid, faceIndices) in result.uncoveredFaces {
            guard let anchor = anchorsByID[uuid] else { continue }
            let geo = anchor.geometry
            let transform = anchor.transform
            for faceIdx in faceIndices {
                let idx = geo.faceIndices(at: faceIdx)
                let v0 = geo.vertex(at: idx[0])
                let v1 = geo.vertex(at: idx[1])
                let v2 = geo.vertex(at: idx[2])
                let w0 = transform * SIMD4<Float>(v0.x, v0.y, v0.z, 1)
                let w1 = transform * SIMD4<Float>(v1.x, v1.y, v1.z, 1)
                let w2 = transform * SIMD4<Float>(v2.x, v2.y, v2.z, 1)
                faces.append(CloudUploader.UncoveredFace(vertices: [
                    [w0.x, w0.y, w0.z],
                    [w1.x, w1.y, w1.z],
                    [w2.x, w2.y, w2.z]
                ]))
            }
        }
        return faces
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
