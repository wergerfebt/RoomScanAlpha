// UIViewRepresentable wrapping ARSCNView that renders LiDAR mesh as a color-coded wireframe overlay.

import SwiftUI
import ARKit
import SceneKit

struct ARScanningView: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let viewModel: ScanViewModel

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView()
        scnView.session = sessionManager.session
        scnView.delegate = context.coordinator
        scnView.automaticallyUpdatesLighting = true
        scnView.rendersContinuously = true
        return scnView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let viewModel: ScanViewModel

        // P-4: Cache geometry signature per anchor to avoid rebuilding unchanged meshes.
        // Key is the anchor's UUID; value is (vertexCount, faceCount) at last rebuild.
        private var anchorGeometryCache: [UUID: (vertices: Int, faces: Int)] = [:]

        // P-5: Running triangle count, updated incrementally instead of recomputed from all anchors.
        private var totalTriangleCount: Int = 0
        private var anchorTriangleCounts: [UUID: Int] = [:]
        private var totalAnchorCount: Int = 0

        init(viewModel: ScanViewModel) {
            self.viewModel = viewModel
        }

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
            let node = SCNNode()
            node.addChildNode(buildMeshNode(for: meshAnchor))

            let faceCount = meshAnchor.geometry.faces.count
            anchorGeometryCache[meshAnchor.identifier] = (
                vertices: meshAnchor.geometry.vertices.count,
                faces: faceCount
            )

            // P-5: Track this anchor's contribution to the total
            anchorTriangleCounts[meshAnchor.identifier] = faceCount
            totalTriangleCount += faceCount
            totalAnchorCount += 1
            pushStats()

            return node
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }

            let newVertexCount = meshAnchor.geometry.vertices.count
            let newFaceCount = meshAnchor.geometry.faces.count

            // P-4: Only rebuild geometry if vertex or face count changed
            if let cached = anchorGeometryCache[meshAnchor.identifier],
               cached.vertices == newVertexCount && cached.faces == newFaceCount {
                return
            }

            node.childNodes.forEach { $0.removeFromParentNode() }
            node.addChildNode(buildMeshNode(for: meshAnchor))
            anchorGeometryCache[meshAnchor.identifier] = (vertices: newVertexCount, faces: newFaceCount)

            // P-5: Update delta instead of recomputing from all anchors
            let oldCount = anchorTriangleCounts[meshAnchor.identifier] ?? 0
            anchorTriangleCounts[meshAnchor.identifier] = newFaceCount
            totalTriangleCount += (newFaceCount - oldCount)
            pushStats()
        }

        func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }

            anchorGeometryCache.removeValue(forKey: meshAnchor.identifier)

            if let removed = anchorTriangleCounts.removeValue(forKey: meshAnchor.identifier) {
                totalTriangleCount -= removed
                totalAnchorCount -= 1
                pushStats()
            }
        }

        private func buildMeshNode(for meshAnchor: ARMeshAnchor) -> SCNNode {
            let geometry = MeshExtractor.buildLocalSCNGeometry(from: meshAnchor)
            let color = MeshExtractor.classificationColor(
                for: MeshExtractor.dominantClassification(for: meshAnchor)
            )

            let material = SCNMaterial()
            material.fillMode = .lines
            material.diffuse.contents = color.withAlphaComponent(0.7)
            material.isDoubleSided = true
            geometry.materials = [material]

            return SCNNode(geometry: geometry)
        }

        private func pushStats() {
            let triangles = totalTriangleCount
            let anchors = totalAnchorCount
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.updateMeshStats(
                    triangleCount: triangles,
                    anchorCount: anchors
                )
            }
        }
    }
}
