// Shows per-face coverage analysis results as an AR overlay.
// Faces with no viable camera candidate are highlighted in red.
// User can continue scanning to fill gaps or proceed to annotation.

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
            CoverageARView(
                sessionManager: sessionManager,
                uncoveredFaces: viewModel.uncoveredFaces
            )
            .ignoresSafeArea()

            VStack {
                statusBadge
                    .padding(.top, 8)

                Spacer()

                controlBar
                    .padding(.bottom, 32)
            }
        }
    }

    private var statusBadge: some View {
        let pct = Int(viewModel.coverageRatio * 100)
        let uncovered = viewModel.uncoveredFaces.values.reduce(0) { $0 + $1.count }
        let analyzing = viewModel.isAnalyzingCoverage
        let color: Color = pct >= 95 ? .green : pct >= 80 ? .yellow : .red

        return HStack(spacing: 8) {
            if analyzing {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Analyzing coverage...")
            } else if uncovered == 0 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("All faces covered")
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text("\(pct)% covered")
                    .fontWeight(.semibold)
                Text("Scan red areas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private var controlBar: some View {
        HStack(spacing: 20) {
            Button(action: onContinueScanning) {
                Label("Continue Scanning", systemImage: "camera.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }

            Button(action: onLooksGood) {
                Label("Looks Good", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Coverage AR View

/// Renders the AR camera feed with red overlay on uncovered mesh faces.
private struct CoverageARView: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let uncoveredFaces: [UUID: Set<Int>]

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView()
        scnView.session = sessionManager.session
        scnView.automaticallyUpdatesLighting = true
        scnView.rendersContinuously = true
        context.coordinator.scnView = scnView
        context.coordinator.sessionManager = sessionManager
        return scnView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.uncoveredFaces = uncoveredFaces
        context.coordinator.rebuildOverlay()

        // If uncoveredFaces is empty (analysis still running), retry after a delay
        if uncoveredFaces.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                context.coordinator.rebuildOverlay()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(uncoveredFaces: uncoveredFaces)
    }

    final class Coordinator: NSObject {
        var uncoveredFaces: [UUID: Set<Int>]
        weak var scnView: ARSCNView?
        weak var sessionManager: ARSessionManager?
        private let overlayTag = "coverageOverlay"

        init(uncoveredFaces: [UUID: Set<Int>]) {
            self.uncoveredFaces = uncoveredFaces
        }

        func rebuildOverlay() {
            guard let scnView = scnView else { return }
            guard !uncoveredFaces.isEmpty else { return }

            // Remove old overlay nodes
            scnView.scene.rootNode.childNodes
                .filter { $0.name == overlayTag }
                .forEach { $0.removeFromParentNode() }

            // Use lastMeshAnchors as primary source (snapshotted and reliable),
            // fall back to live session frame
            let meshAnchors: [ARMeshAnchor]
            if let snapshotted = sessionManager?.lastMeshAnchors, !snapshotted.isEmpty {
                meshAnchors = snapshotted
            } else if let frame = scnView.session.currentFrame {
                meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            } else {
                return
            }

            for meshAnchor in meshAnchors {
                guard let faceSet = uncoveredFaces[meshAnchor.identifier], !faceSet.isEmpty else { continue }

                if let geometry = buildUncoveredGeometry(meshAnchor: meshAnchor, faceIndices: faceSet) {
                    let material = SCNMaterial()
                    material.fillMode = .fill
                    material.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.4)
                    material.isDoubleSided = true
                    material.lightingModel = .constant
                    geometry.materials = [material]

                    let node = SCNNode(geometry: geometry)
                    node.name = overlayTag
                    node.simdTransform = meshAnchor.transform
                    scnView.scene.rootNode.addChildNode(node)
                }
            }
        }

        /// Build SCNGeometry from specific face indices of a mesh anchor (in local space).
        private func buildUncoveredGeometry(meshAnchor: ARMeshAnchor, faceIndices: Set<Int>) -> SCNGeometry? {
            let geo = meshAnchor.geometry
            var reindex = [UInt32: UInt32]()
            var vertices = [SCNVector3]()
            var normals = [SCNVector3]()
            var indices = [UInt32]()
            var nextIdx: UInt32 = 0

            for faceIdx in faceIndices {
                guard faceIdx < geo.faces.count else { continue }
                let face = geo.faceIndices(at: faceIdx)
                for oldIdx in face {
                    if let mapped = reindex[oldIdx] {
                        indices.append(mapped)
                    } else {
                        let v = geo.vertex(at: oldIdx)
                        vertices.append(SCNVector3(v.x, v.y, v.z))
                        let n = geo.normal(at: oldIdx)
                        normals.append(SCNVector3(n.x, n.y, n.z))
                        reindex[oldIdx] = nextIdx
                        indices.append(nextIdx)
                        nextIdx += 1
                    }
                }
            }

            guard !indices.isEmpty else { return nil }

            let vertexSource = SCNGeometrySource(vertices: vertices)
            let normalSource = SCNGeometrySource(normals: normals)
            let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
            return SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        }
    }
}
