// Converts ARMeshAnchor geometry for rendering (SCNGeometry) and export (world-space vertices).
// Also provides classification color mapping for the wireframe overlay.

import ARKit
import SceneKit

struct MeshExtractor {

    /// Build SCNGeometry in the anchor's local coordinate space.
    /// Use this for ARSCNView rendering where the node inherits the anchor's world transform.
    ///
    /// - Parameter faceStride: Render every Nth face. 1 = full fidelity, 4 = ~25% of faces (good for wireframe).
    static func buildLocalSCNGeometry(from meshAnchor: ARMeshAnchor, faceStride: Int = 1) -> SCNGeometry {
        let geometry = meshAnchor.geometry
        let faceCount = geometry.faces.count
        let stride = max(1, faceStride)

        // When decimating, only extract vertices referenced by the faces we keep.
        // This avoids iterating all vertices when we only need a fraction.
        if stride > 1 {
            var reindex = [UInt32: UInt32]() // old vertex index → new index
            var vertices = [SCNVector3]()
            var normals = [SCNVector3]()
            var indices = [UInt32]()
            let decimatedCount = (faceCount + stride - 1) / stride
            vertices.reserveCapacity(decimatedCount * 3)
            normals.reserveCapacity(decimatedCount * 3)
            indices.reserveCapacity(decimatedCount * 3)

            var nextIdx: UInt32 = 0
            for i in Swift.stride(from: 0, to: faceCount, by: stride) {
                let face = geometry.faceIndices(at: i)
                for oldIdx in face {
                    if let mapped = reindex[oldIdx] {
                        indices.append(mapped)
                    } else {
                        let v = geometry.vertex(at: oldIdx)
                        vertices.append(SCNVector3(v[0], v[1], v[2]))
                        let n = geometry.normal(at: oldIdx)
                        normals.append(SCNVector3(n[0], n[1], n[2]))
                        reindex[oldIdx] = nextIdx
                        indices.append(nextIdx)
                        nextIdx += 1
                    }
                }
            }

            let vertexSource = SCNGeometrySource(vertices: vertices)
            let normalSource = SCNGeometrySource(normals: normals)
            let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
            return SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        }

        // Full fidelity path (stride == 1)
        let vertexCount = geometry.vertices.count

        var vertices = [SCNVector3]()
        vertices.reserveCapacity(vertexCount)
        for i in 0..<vertexCount {
            let v = geometry.vertex(at: UInt32(i))
            vertices.append(SCNVector3(v[0], v[1], v[2]))
        }

        var normals = [SCNVector3]()
        normals.reserveCapacity(vertexCount)
        for i in 0..<vertexCount {
            let n = geometry.normal(at: UInt32(i))
            normals.append(SCNVector3(n[0], n[1], n[2]))
        }

        var indices = [UInt32]()
        indices.reserveCapacity(faceCount * 3)
        for i in 0..<faceCount {
            let face = geometry.faceIndices(at: i)
            indices.append(contentsOf: face)
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

        return SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
    }

    static func classificationColor(for classification: ARMeshClassification) -> UIColor {
        switch classification {
        case .wall:    return .systemBlue
        case .floor:   return .systemGreen
        case .ceiling: return .systemYellow
        case .table:   return .systemOrange
        case .seat:    return .systemPurple
        case .window:  return .systemCyan
        case .door:    return .systemBrown
        case .none:    return .lightGray
        @unknown default: return .lightGray
        }
    }

    static func dominantClassification(for meshAnchor: ARMeshAnchor) -> ARMeshClassification {
        let geometry = meshAnchor.geometry
        let faceCount = geometry.faces.count
        guard faceCount > 0 else { return .none }

        var counts = [ARMeshClassification: Int]()
        for i in 0..<faceCount {
            let c = geometry.classificationOf(faceWithIndex: i)
            counts[c, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? .none
    }

    static func triangleCount(for anchors: [ARMeshAnchor]) -> Int {
        anchors.reduce(0) { $0 + $1.geometry.faces.count }
    }
}
