import SwiftUI
import ARKit
import SceneKit

/// AR overlay showing orange patches at uncovered face locations.
/// The user walks to these patches while the app captures supplemental frames.
struct GapRescanView: View {
    let sessionManager: ARSessionManager
    let viewModel: ScanViewModel
    let uncoveredFaces: [CloudUploader.UncoveredFace]
    let holeFaces: [CloudUploader.UncoveredFace]
    let onStop: () -> Void

    @State private var supplementalFrameCount: Int = 0

    var body: some View {
        ZStack {
            ARGapOverlaySceneView(
                sessionManager: sessionManager,
                uncoveredFaces: uncoveredFaces,
                holeFaces: holeFaces,
                onFrameCountUpdate: { count in
                    supplementalFrameCount = count
                }
            )
            .ignoresSafeArea()

            VStack {
                // Top status bar
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Circle().fill(.orange).frame(width: 8, height: 8)
                                Text("\(uncoveredFaces.count) untextured")
                            }
                            if !holeFaces.isEmpty {
                                HStack(spacing: 4) {
                                    Circle().fill(.red).frame(width: 8, height: 8)
                                    Text("\(holeFaces.count) holes")
                                }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.white)
                        Text("\(supplementalFrameCount) supplemental frames")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Text("Walk to highlighted areas")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
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
            sessionManager.frameCaptureManager.reset()
            sessionManager.frameCaptureManager.videoWriter.prewarm()
            sessionManager.isCapturing = true
            print("[RoomScanAlpha] Gap rescan started — \(uncoveredFaces.count) untextured, \(holeFaces.count) holes")
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
    let holeFaces: [CloudUploader.UncoveredFace]
    let onFrameCountUpdate: (Int) -> Void

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView()
        scnView.session = sessionManager.session
        scnView.delegate = context.coordinator
        scnView.automaticallyUpdatesLighting = true
        scnView.rendersContinuously = true

        // Orange: untextured faces (OpenMVS couldn't assign a camera)
        if !uncoveredFaces.isEmpty {
            let gapMesh = buildOverlayMesh(faces: uncoveredFaces, color: .orange)
            gapMesh.name = "gapPatches"
            scnView.scene.rootNode.addChildNode(gapMesh)
        }

        // Red: mesh holes (rays escape without hitting geometry)
        if !holeFaces.isEmpty {
            let holeMesh = buildOverlayMesh(faces: holeFaces, color: .red)
            holeMesh.name = "holePatches"
            scnView.scene.rootNode.addChildNode(holeMesh)
        }

        return scnView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionManager: sessionManager, onFrameCountUpdate: onFrameCountUpdate)
    }

    private func buildOverlayMesh(faces: [CloudUploader.UncoveredFace], color: UIColor) -> SCNNode {
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
        material.diffuse.contents = color.withAlphaComponent(0.8)
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
