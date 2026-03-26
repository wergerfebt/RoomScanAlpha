import ARKit

struct PLYExporter {

    /// Export mesh anchors to a binary PLY file at the given URL.
    /// Vertices are transformed to world space. Each face includes a classification label.
    static func export(meshAnchors: [ARMeshAnchor], to fileURL: URL) throws {
        var allVertices = [SIMD3<Float>]()
        var allNormals = [SIMD3<Float>]()
        var allFaces = [[UInt32]]()
        var allClassifications = [UInt8]()
        var vertexOffset: UInt32 = 0

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let worldTransform = anchor.transform
            let normalTransform = simd_float3x3(
                SIMD3<Float>(worldTransform.columns.0.x, worldTransform.columns.0.y, worldTransform.columns.0.z),
                SIMD3<Float>(worldTransform.columns.1.x, worldTransform.columns.1.y, worldTransform.columns.1.z),
                SIMD3<Float>(worldTransform.columns.2.x, worldTransform.columns.2.y, worldTransform.columns.2.z)
            )

            let vertexCount = geometry.vertices.count
            for i in 0..<vertexCount {
                let v = geometry.vertex(at: UInt32(i))
                let local4 = SIMD4<Float>(v[0], v[1], v[2], 1.0)
                let world4 = simd_mul(worldTransform, local4)
                allVertices.append(SIMD3<Float>(world4.x, world4.y, world4.z))

                let n = geometry.normal(at: UInt32(i))
                let localN = SIMD3<Float>(n[0], n[1], n[2])
                let worldN = simd_mul(normalTransform, localN)
                allNormals.append(worldN)
            }

            let faceCount = geometry.faces.count
            for i in 0..<faceCount {
                let indices = geometry.faceIndices(at: i)
                let offsetIndices = indices.map { $0 + vertexOffset }
                allFaces.append(offsetIndices)

                let classification = geometry.classificationOf(faceWithIndex: i)
                allClassifications.append(UInt8(classification.rawValue))
            }

            vertexOffset += UInt32(vertexCount)
        }

        let totalVertices = allVertices.count
        let totalFaces = allFaces.count

        // Build binary PLY
        var header = """
        ply
        format binary_little_endian 1.0
        element vertex \(totalVertices)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz
        element face \(totalFaces)
        property list uchar uint vertex_indices
        property uchar classification
        end_header\n
        """

        var data = Data(header.utf8)

        // Vertex data
        for i in 0..<totalVertices {
            var v = allVertices[i]
            var n = allNormals[i]
            data.append(Data(bytes: &v.x, count: 4))
            data.append(Data(bytes: &v.y, count: 4))
            data.append(Data(bytes: &v.z, count: 4))
            data.append(Data(bytes: &n.x, count: 4))
            data.append(Data(bytes: &n.y, count: 4))
            data.append(Data(bytes: &n.z, count: 4))
        }

        // Face data
        for i in 0..<totalFaces {
            let face = allFaces[i]
            var count: UInt8 = UInt8(face.count)
            data.append(Data(bytes: &count, count: 1))
            for var idx in face {
                data.append(Data(bytes: &idx, count: 4))
            }
            var classification = allClassifications[i]
            data.append(Data(bytes: &classification, count: 1))
        }

        try data.write(to: fileURL)

        print("[RoomScanAlpha] PLY exported: \(totalVertices) vertices, \(totalFaces) faces, \(data.count / 1024)KB")
    }
}
