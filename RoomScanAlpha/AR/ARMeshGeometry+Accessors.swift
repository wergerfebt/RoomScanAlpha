// Safe accessors for reading vertices, normals, face indices, and classifications from ARMeshGeometry
// metal buffers. Used by both MeshExtractor (rendering) and PLYExporter (export).

import ARKit

extension ARMeshGeometry {
    func vertex(at index: UInt32) -> SIMD3<Float> {
        let pointer = vertices.buffer.contents().advanced(by: vertices.offset + Int(index) * vertices.stride)
        return pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }

    func normal(at index: UInt32) -> SIMD3<Float> {
        let pointer = normals.buffer.contents().advanced(by: normals.offset + Int(index) * normals.stride)
        return pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }

    func faceIndices(at index: Int) -> [UInt32] {
        let pointer = faces.buffer.contents().advanced(by: faces.indexCountPerPrimitive * index * MemoryLayout<UInt32>.size)
        let buffer = UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt32.self), count: faces.indexCountPerPrimitive)
        return Array(buffer)
    }

    func classificationOf(faceWithIndex index: Int) -> ARMeshClassification {
        guard let classificationBuffer = classification else { return .none }
        let pointer = classificationBuffer.buffer.contents().advanced(by: classificationBuffer.offset + index * classificationBuffer.stride)
        let rawValue = pointer.assumingMemoryBound(to: UInt8.self).pointee
        return ARMeshClassification(rawValue: Int(rawValue)) ?? .none
    }
}
