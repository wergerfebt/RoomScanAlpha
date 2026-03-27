// Converts ARMeshAnchor geometry for rendering (SCNGeometry) and export (world-space vertices).
// Also provides classification color mapping for the wireframe overlay.

import ARKit
import SceneKit

struct MeshExtractor {

    /// Build SCNGeometry in the anchor's local coordinate space.
    /// Use this for ARSCNView rendering where the node inherits the anchor's world transform.
    static func buildLocalSCNGeometry(from meshAnchor: ARMeshAnchor) -> SCNGeometry {
        let geometry = meshAnchor.geometry
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

        let faceCount = geometry.faces.count
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
