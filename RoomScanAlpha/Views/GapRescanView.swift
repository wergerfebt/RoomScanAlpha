import SwiftUI
import ARKit
import SceneKit

/// AR overlay showing orange patches at uncovered face locations.
/// The user walks to these patches while the app captures supplemental frames.
struct GapRescanView: View {
    let sessionManager: ARSessionManager
    let viewModel: ScanViewModel
    let uncoveredFaces: [CloudUploader.UncoveredFace]
    let onStop: () -> Void

    @State private var supplementalFrameCount: Int = 0

    var body: some View {
        ZStack {
            ARGapOverlaySceneView(
                sessionManager: sessionManager,
                uncoveredFaces: uncoveredFaces,
                onFrameCountUpdate: { count in
                    supplementalFrameCount = count
                }
            )
            .ignoresSafeArea()

            VStack {
                // Top status bar
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(uncoveredFaces.count) gap patches")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("\(supplementalFrameCount) supplemental frames")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Text("Walk to orange areas")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding()
                .background(.black.opacity(0.6))
                .padding(.top, 50)

                Spacer()

                // Stop button
                Button(action: onStop) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                        Text("Stop Re-scan")
                            .font(.headline)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(.red)
                    .clipShape(Capsule())
                }
                .padding(.bottom, 48)
            }
        }
        .onAppear {
            sessionManager.isCapturing = true
            sessionManager.frameCaptureManager.reset()
            print("[RoomScanAlpha] Gap rescan started — \(uncoveredFaces.count) patches")
        }
        .onDisappear {
            sessionManager.isCapturing = false
        }
    }
}

// MARK: - AR Scene View with Gap Patches

private struct ARGapOverlaySceneView: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let uncoveredFaces: [CloudUploader.UncoveredFace]
    let onFrameCountUpdate: (Int) -> Void

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView()
        scnView.session = sessionManager.session
        scnView.delegate = context.coordinator
        scnView.automaticallyUpdatesLighting = true
        scnView.rendersContinuously = true

        // Add gap triangles as a single merged mesh
        let gapMesh = buildGapMesh(faces: uncoveredFaces)
        gapMesh.name = "gapPatches"
        scnView.scene.rootNode.addChildNode(gapMesh)

        return scnView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionManager: sessionManager, onFrameCountUpdate: onFrameCountUpdate)
    }

    /// Build a single SCNNode containing all gap triangles as one merged geometry.
    /// Much more efficient than one node per face, and renders the actual triangle shape.
    private func buildGapMesh(faces: [CloudUploader.UncoveredFace]) -> SCNNode {
        var positions: [SCNVector3] = []
        var indices: [UInt32] = []

        for face in faces {
            guard face.vertices.count == 3 else { continue }
            let baseIndex = UInt32(positions.count)
            for v in face.vertices {
                positions.append(SCNVector3(v[0], v[1], v[2]))
            }
            indices.append(contentsOf: [baseIndex, baseIndex + 1, baseIndex + 2])
        }

        let vertexSource = SCNGeometrySource(vertices: positions)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = UIColor.orange.withAlphaComponent(0.5)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 100
        return node
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let sessionManager: ARSessionManager
        let onFrameCountUpdate: (Int) -> Void
        private var lastReportedCount = 0

        init(sessionManager: ARSessionManager, onFrameCountUpdate: @escaping (Int) -> Void) {
            self.sessionManager = sessionManager
            self.onFrameCountUpdate = onFrameCountUpdate
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let count = sessionManager.frameCaptureManager.keyframeCount
            if count != lastReportedCount {
                lastReportedCount = count
                DispatchQueue.main.async {
                    self.onFrameCountUpdate(count)
                }
            }
        }
    }
}
