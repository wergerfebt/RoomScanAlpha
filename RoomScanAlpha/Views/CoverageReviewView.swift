// Inline coverage review — shown between scan-stop and corner annotation.
// Runs on-device in 2-5s, renders red/orange overlay spheres on uncovered
// mesh faces so the user can walk back for more coverage without waiting
// on the cloud `/coverage` endpoint.
//
// Critical constraint: keep the AR session running the whole time. Pausing
// between scan and export re-initializes ARKit's world origin, causing
// 1-2ft texture misalignment (see CLAUDE.md).

import SwiftUI
import ARKit
import SceneKit

struct CoverageReviewView: View {
    let sessionManager: ARSessionManager
    let viewModel: ScanViewModel
    let onContinueScanning: () -> Void
    let onLooksGood: () -> Void

    var body: some View {
        ZStack {
            // Live AR camera feed — same coordinates as the scanning session.
            CoverageOverlaySceneView(
                sessionManager: sessionManager,
                uncoveredFaces: viewModel.localUncoveredFaces,
                holes: viewModel.localHoles
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                statusBanner
                    .padding(.top, 8)

                Spacer()

                controlBar
                    .padding(.bottom, 32)
            }
            .dynamicTypeSize(.large ... .accessibility2)
        }
    }

    // MARK: - Status banner

    private var statusBanner: some View {
        VStack(spacing: 8) {
            if viewModel.isAnalyzingCoverage {
                analyzingBanner
            } else {
                coverageBanner
            }
        }
        .padding(.horizontal, 16)
    }

    private var analyzingBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Analyzing coverage…")
                    .font(.headline)
                Text("About 5 seconds")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var coverageBanner: some View {
        let holeCount = viewModel.localHoles.count
        let texturePct = Int((viewModel.coverageRatio * 100).rounded())
        let tier = holeTier(holeCount: holeCount, texturePct: texturePct)

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: tier.icon)
                .font(.title)
                .foregroundStyle(tier.color)
            VStack(alignment: .leading, spacing: 6) {
                Text(tier.headline)
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)

                if holeCount > 0 {
                    Text("Red markers show where the mesh has holes. Walk toward them and point the camera at the gap.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Text("\(texturePct)% texture coverage · \(viewModel.localUncoveredCount) gap\(viewModel.localUncoveredCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func holeTier(holeCount: Int, texturePct: Int) -> (icon: String, color: Color, headline: String) {
        if holeCount == 0 && texturePct >= 90 {
            return ("checkmark.shield.fill", .green, "No holes detected")
        }
        if holeCount == 0 {
            return ("exclamationmark.triangle.fill", .yellow, "\(texturePct)% textured — fill the patches")
        }
        return ("xmark.shield.fill", .red, "\(holeCount) hole\(holeCount == 1 ? "" : "s") in the mesh")
    }

    // MARK: - Controls

    private var controlBar: some View {
        VStack(spacing: 12) {
            if viewModel.isAnalyzingCoverage {
                EmptyView()
            } else if shouldProceed {
                Button {
                    onLooksGood()
                } label: {
                    Label("Continue", systemImage: "arrow.right")
                }
                .largeCapsuleButton(role: .primary, tint: .green)
                .padding(.horizontal, 24)
            } else {
                Button {
                    onContinueScanning()
                } label: {
                    Label("Scan missing areas", systemImage: "camera.viewfinder")
                }
                .largeCapsuleButton(role: .primary, tint: .blue)
                .padding(.horizontal, 24)

                Button {
                    onLooksGood()
                } label: {
                    Label("Continue anyway", systemImage: "exclamationmark.triangle")
                }
                .largeCapsuleButton(role: .secondary)
                .padding(.horizontal, 24)
            }
        }
    }

    /// Automatically proceed only when the ray-cast found no holes and texture
    /// coverage is strong. Zero holes means every direction from scan centroid
    /// eventually hits mesh — i.e., the room is sealed.
    private var shouldProceed: Bool {
        viewModel.localHoles.isEmpty && viewModel.coverageRatio >= 0.85
    }

    // MARK: - Helpers

    private func coverageTier(_ pct: Int) -> (icon: String, color: Color) {
        if pct >= 90 {
            return ("checkmark.shield.fill", .green)
        } else if pct >= 80 {
            return ("exclamationmark.triangle.fill", .yellow)
        } else {
            return ("xmark.circle.fill", .red)
        }
    }
}

// MARK: - AR Scene with gap overlay

private struct CoverageOverlaySceneView: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let uncoveredFaces: [CloudUploader.UncoveredFace]
    let holes: [MeshCoverageAnalyzer.HoleSample]

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView()
        scnView.session = sessionManager.session
        scnView.automaticallyUpdatesLighting = true
        scnView.rendersContinuously = true
        return scnView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        let gapTag = "coverageGapPatches"
        let holeTag = "coverageHoleMarkers"
        uiView.scene.rootNode.childNodes
            .filter { $0.name == gapTag || $0.name == holeTag }
            .forEach { $0.removeFromParentNode() }

        if !uncoveredFaces.isEmpty {
            let overlay = buildOverlayMesh(faces: uncoveredFaces, color: .orange)
            overlay.name = gapTag
            uiView.scene.rootNode.addChildNode(overlay)
        }

        if !holes.isEmpty {
            let group = SCNNode()
            group.name = holeTag
            for hole in holes {
                group.addChildNode(buildHoleMarker(at: hole.worldPosition))
            }
            uiView.scene.rootNode.addChildNode(group)
        }
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

    private func buildHoleMarker(at position: SIMD3<Float>) -> SCNNode {
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
}
