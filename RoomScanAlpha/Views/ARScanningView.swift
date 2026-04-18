// UIViewRepresentable wrapping ARSCNView that renders LiDAR mesh as a color-coded wireframe overlay.

import SwiftUI
import ARKit
import SceneKit

struct ARScanningView: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let viewModel: ScanViewModel
    /// Red AR spheres at hole positions from the most recent coverage review.
    /// Persists across a "Scan missing areas" re-scan so the user can walk toward them.
    var holes: [MeshCoverageAnalyzer.HoleSample] = []
    /// Orange triangle overlay marking untextured mesh faces from the last coverage pass.
    var uncoveredFaces: [CloudUploader.UncoveredFace] = []

    private static let holeTag = "scanHoleMarkers"
    private static let gapTag = "scanGapPatches"

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView()
        scnView.session = sessionManager.session
        scnView.delegate = context.coordinator
        scnView.automaticallyUpdatesLighting = true
        scnView.rendersContinuously = true

        // Re-mount case: ScanningView was torn down (coverage review) and is
        // now coming back with a still-running AR session. ARKit won't re-emit
        // `didAdd` for pre-existing anchors to the new delegate, so seed the
        // coordinator's running counts from the session's current anchors.
        if let frame = sessionManager.session.currentFrame {
            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            context.coordinator.seedFromExistingAnchors(meshAnchors)
        }

        return scnView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        uiView.scene.rootNode.childNodes
            .filter { $0.name == Self.holeTag || $0.name == Self.gapTag }
            .forEach { $0.removeFromParentNode() }

        if !uncoveredFaces.isEmpty {
            let gapNode = Self.buildGapMesh(faces: uncoveredFaces)
            gapNode.name = Self.gapTag
            uiView.scene.rootNode.addChildNode(gapNode)
        }

        if !holes.isEmpty {
            let group = SCNNode()
            group.name = Self.holeTag
            for hole in holes {
                group.addChildNode(Self.buildHoleMarker(at: hole.worldPosition))
            }
            uiView.scene.rootNode.addChildNode(group)
        }
    }

    // MARK: - Overlay Builders

    private static func buildGapMesh(faces: [CloudUploader.UncoveredFace]) -> SCNNode {
        var positions: [SCNVector3] = []
        var indices: [UInt32] = []
        for face in faces {
            guard face.vertices.count == 3 else { continue }
            let base = UInt32(positions.count)
            for v in face.vertices {
                positions.append(SCNVector3(v[0], v[1], v[2]))
            }
            indices.append(contentsOf: [base, base + 1, base + 2])
        }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: positions)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.orange.withAlphaComponent(0.8)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 100
        return node
    }

    private static func buildHoleMarker(at position: SIMD3<Float>) -> SCNNode {
        let sphere = SCNSphere(radius: 0.12)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.85)
        material.emission.contents = UIColor.systemRed.withAlphaComponent(0.5)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        node.position = SCNVector3(position.x, position.y, position.z)
        node.renderingOrder = 110
        return node
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let viewModel: ScanViewModel

        // Performance: cache geometry signature per anchor to avoid rebuilding unchanged meshes.
        // Key is the anchor's UUID; value is (vertexCount, faceCount) at last rebuild.
        private var anchorGeometryCache: [UUID: (vertices: Int, faces: Int)] = [:]

        // Performance: running triangle count, updated incrementally instead of recomputed from all anchors.
        private var totalTriangleCount: Int = 0
        private var anchorTriangleCounts: [UUID: Int] = [:]
        private var totalAnchorCount: Int = 0

        init(viewModel: ScanViewModel) {
            self.viewModel = viewModel
        }

        /// Pre-populate running counts from anchors that already existed in the
        /// AR session before this coordinator was created (e.g., returning from
        /// the inline coverage review). Idempotent with `nodeFor(_:)` — if ARKit
        /// later re-delivers these anchors as `didAdd`, the delta path kicks in.
        func seedFromExistingAnchors(_ anchors: [ARMeshAnchor]) {
            for anchor in anchors where anchorTriangleCounts[anchor.identifier] == nil {
                let faceCount = anchor.geometry.faces.count
                anchorTriangleCounts[anchor.identifier] = faceCount
                anchorGeometryCache[anchor.identifier] = (
                    vertices: anchor.geometry.vertices.count,
                    faces: faceCount
                )
                totalTriangleCount += faceCount
                totalAnchorCount += 1
            }
            pushStats()
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

            // If we've already seen this anchor (e.g., seeded on remount and
            // ARKit is now re-announcing it), apply a delta instead of adding.
            if let prev = anchorTriangleCounts[meshAnchor.identifier] {
                totalTriangleCount += (faceCount - prev)
                anchorTriangleCounts[meshAnchor.identifier] = faceCount
            } else {
                anchorTriangleCounts[meshAnchor.identifier] = faceCount
                totalTriangleCount += faceCount
                totalAnchorCount += 1
            }
            pushStats()

            return node
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }

            let newVertexCount = meshAnchor.geometry.vertices.count
            let newFaceCount = meshAnchor.geometry.faces.count

            // Skip rebuild if geometry hasn't changed (same vertex/face counts)
            if let cached = anchorGeometryCache[meshAnchor.identifier],
               cached.vertices == newVertexCount && cached.faces == newFaceCount {
                return
            }

            node.childNodes.forEach { $0.removeFromParentNode() }
            node.addChildNode(buildMeshNode(for: meshAnchor))
            anchorGeometryCache[meshAnchor.identifier] = (vertices: newVertexCount, faces: newFaceCount)

            // Update triangle count incrementally (delta) instead of recomputing from all anchors
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

        /// Render every 4th face — wireframe overlay doesn't need full density.
        private static let wireframeStride = 4

        private func buildMeshNode(for meshAnchor: ARMeshAnchor) -> SCNNode {
            let geometry = MeshExtractor.buildLocalSCNGeometry(from: meshAnchor, faceStride: Self.wireframeStride)
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
