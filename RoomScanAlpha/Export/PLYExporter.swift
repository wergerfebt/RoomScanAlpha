// Converts ARMeshAnchor data to binary PLY format for upload to the cloud scan processor.
// Uses a two-pass streaming approach: first pass counts totals for the header,
// second pass writes binary data directly per-anchor without intermediate arrays.

import ARKit

struct PLYExporter {

    struct ExportCounts {
        let vertexCount: Int
        let faceCount: Int
    }

    /// Export mesh anchors to a binary PLY file at the given URL.
    /// Vertices are transformed to world space. Each face includes a classification label.
    /// Returns vertex and face counts so callers don't need to re-iterate the anchors.
    @discardableResult
    static func export(meshAnchors: [ARMeshAnchor], to fileURL: URL) throws -> ExportCounts {
        // Pass 1: count totals for header
        var totalVertices = 0
        var totalFaces = 0
        for anchor in meshAnchors {
            totalVertices += anchor.geometry.vertices.count
            totalFaces += anchor.geometry.faces.count
        }

        let header = buildHeader(vertexCount: totalVertices, faceCount: totalFaces)

        // Pass 2: stream binary data directly to file
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        defer { fileHandle.closeFile() }

        fileHandle.write(Data(header.utf8))

        // Write vertices per-anchor (no intermediate array).
        // Each vertex is 24 bytes: 6 × little-endian float32 (x, y, z, nx, ny, nz).
        // Positions are transformed from anchor-local to world space via the 4×4 anchor transform.
        // Normals use only the upper-left 3×3 rotation submatrix (translation doesn't apply to normals).
        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let worldTransform = anchor.transform
            // Extract the 3×3 rotation from the 4×4 transform for normal transformation
            let normalTransform = simd_float3x3(
                SIMD3<Float>(worldTransform.columns.0.x, worldTransform.columns.0.y, worldTransform.columns.0.z),
                SIMD3<Float>(worldTransform.columns.1.x, worldTransform.columns.1.y, worldTransform.columns.1.z),
                SIMD3<Float>(worldTransform.columns.2.x, worldTransform.columns.2.y, worldTransform.columns.2.z)
            )

            let bytesPerVertex = 24  // 6 floats × 4 bytes
            var vertexData = Data(capacity: geometry.vertices.count * bytesPerVertex)
            for i in 0..<geometry.vertices.count {
                // Transform position: multiply by 4×4 with w=1.0 for affine transform, then discard w
                let v = geometry.vertex(at: UInt32(i))
                let local4 = SIMD4<Float>(v[0], v[1], v[2], 1.0)
                let world4 = simd_mul(worldTransform, local4)

                let n = geometry.normal(at: UInt32(i))
                let localN = SIMD3<Float>(n[0], n[1], n[2])
                let worldN = simd_mul(normalTransform, localN)

                var wx = world4.x, wy = world4.y, wz = world4.z
                var nx = worldN.x, ny = worldN.y, nz = worldN.z
                vertexData.append(Data(bytes: &wx, count: 4))
                vertexData.append(Data(bytes: &wy, count: 4))
                vertexData.append(Data(bytes: &wz, count: 4))
                vertexData.append(Data(bytes: &nx, count: 4))
                vertexData.append(Data(bytes: &ny, count: 4))
                vertexData.append(Data(bytes: &nz, count: 4))
            }
            fileHandle.write(vertexData)
        }

        // Write faces per-anchor. Each face is packed as:
        //   1 byte   — vertex count (3 for triangles)
        //   N × 4 bytes — uint32 vertex indices (offset to global index space)
        //   1 byte   — ARMeshClassification raw value
        // Total per triangle: 1 + 12 + 1 = 14 bytes.
        // vertexOffset tracks the cumulative vertex count from prior anchors so that
        // face indices reference the correct global vertex positions.
        var vertexOffset: UInt32 = 0
        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let bytesPerFace = 14  // 1 + 3×4 + 1
            var faceData = Data(capacity: geometry.faces.count * bytesPerFace)
            for i in 0..<geometry.faces.count {
                let indices = geometry.faceIndices(at: i)
                var count: UInt8 = UInt8(indices.count)
                faceData.append(Data(bytes: &count, count: 1))
                for idx in indices {
                    var offsetIdx = idx + vertexOffset
                    faceData.append(Data(bytes: &offsetIdx, count: 4))
                }
                let classification = geometry.classificationOf(faceWithIndex: i)
                var classValue = UInt8(classification.rawValue)
                faceData.append(Data(bytes: &classValue, count: 1))
            }
            fileHandle.write(faceData)

            vertexOffset += UInt32(geometry.vertices.count)
        }

        let fileSize = fileHandle.offsetInFile
        print("[RoomScanAlpha] PLY exported: \(totalVertices) vertices, \(totalFaces) faces, \(fileSize / 1024)KB (streaming)")

        return ExportCounts(vertexCount: totalVertices, faceCount: totalFaces)
    }

    private static func buildHeader(vertexCount: Int, faceCount: Int) -> String {
        """
        ply
        format binary_little_endian 1.0
        element vertex \(vertexCount)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz
        element face \(faceCount)
        property list uchar uint vertex_indices
        property uchar classification
        end_header\n
        """
    }
}
