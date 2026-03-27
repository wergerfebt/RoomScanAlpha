// Converts ARMeshAnchor data to binary PLY format for upload to the cloud scan processor.

import ARKit

struct PLYExporter {

    /// Export mesh anchors to a binary PLY file at the given URL.
    /// Vertices are transformed to world space. Each face includes a classification label.
    static func export(meshAnchors: [ARMeshAnchor], to fileURL: URL) throws {
        let mesh = mergeAnchors(meshAnchors)
        let header = buildHeader(vertexCount: mesh.vertices.count, faceCount: mesh.faces.count)

        var data = Data(header.utf8)
        serializeVertices(mesh.vertices, normals: mesh.normals, into: &data)
        serializeFaces(mesh.faces, classifications: mesh.classifications, into: &data)

        try data.write(to: fileURL)

        print("[RoomScanAlpha] PLY exported: \(mesh.vertices.count) vertices, \(mesh.faces.count) faces, \(data.count / 1024)KB")
    }

    // MARK: - Mesh merging

    private struct MergedMesh {
        let vertices: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
        let faces: [[UInt32]]
        let classifications: [UInt8]
    }

    private static func mergeAnchors(_ anchors: [ARMeshAnchor]) -> MergedMesh {
        var allVertices = [SIMD3<Float>]()
        var allNormals = [SIMD3<Float>]()
        var allFaces = [[UInt32]]()
        var allClassifications = [UInt8]()
        var vertexOffset: UInt32 = 0

        for anchor in anchors {
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

        return MergedMesh(vertices: allVertices, normals: allNormals, faces: allFaces, classifications: allClassifications)
    }

    // MARK: - Header

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

    // MARK: - Binary serialization

    private static func serializeVertices(_ vertices: [SIMD3<Float>], normals: [SIMD3<Float>], into data: inout Data) {
        for i in 0..<vertices.count {
            var v = vertices[i]
            var n = normals[i]
            data.append(Data(bytes: &v.x, count: 4))
            data.append(Data(bytes: &v.y, count: 4))
            data.append(Data(bytes: &v.z, count: 4))
            data.append(Data(bytes: &n.x, count: 4))
            data.append(Data(bytes: &n.y, count: 4))
            data.append(Data(bytes: &n.z, count: 4))
        }
    }

    private static func serializeFaces(_ faces: [[UInt32]], classifications: [UInt8], into data: inout Data) {
        for i in 0..<faces.count {
            let face = faces[i]
            var count: UInt8 = UInt8(face.count)
            data.append(Data(bytes: &count, count: 1))
            for var idx in face {
                data.append(Data(bytes: &idx, count: 4))
            }
            var classification = classifications[i]
            data.append(Data(bytes: &classification, count: 1))
        }
    }
}
