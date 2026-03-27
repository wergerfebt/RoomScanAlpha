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

        init(viewModel: ScanViewModel) {
            self.viewModel = viewModel
        }

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
            let node = SCNNode()
            node.addChildNode(buildMeshNode(for: meshAnchor))
            return node
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            node.childNodes.forEach { $0.removeFromParentNode() }
            node.addChildNode(buildMeshNode(for: meshAnchor))
            updateStats(renderer: renderer)
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

        private func updateStats(renderer: SCNSceneRenderer) {
            guard let scnView = renderer as? ARSCNView,
                  let frame = scnView.session.currentFrame else { return }
            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            let triangles = MeshExtractor.triangleCount(for: meshAnchors)
            let anchorCount = meshAnchors.count

            DispatchQueue.main.async { [weak self] in
                self?.viewModel.updateMeshStats(
                    triangleCount: triangles,
                    anchorCount: anchorCount
                )
            }
        }
    }
}
