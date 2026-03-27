import SwiftUI
import SceneKit
import ARKit

struct MeshViewerView: UIViewRepresentable {
    let meshAnchors: [ARMeshAnchor]

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = buildScene()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = .systemBackground
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func buildScene() -> SCNScene {
        let scene = SCNScene()

        for anchor in meshAnchors {
            let geometry = MeshExtractor.buildLocalSCNGeometry(from: anchor)
            let classification = MeshExtractor.dominantClassification(for: anchor)
            let color = MeshExtractor.classificationColor(for: classification)

            let material = SCNMaterial()
            material.diffuse.contents = color.withAlphaComponent(0.6)
            material.isDoubleSided = true
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.simdTransform = anchor.transform
            scene.rootNode.addChildNode(node)
        }

        // Add ambient light
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 500
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }
}

struct MeshViewerSheet: View {
    let meshAnchors: [ARMeshAnchor]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            MeshViewerView(meshAnchors: meshAnchors)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("3D Scan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
