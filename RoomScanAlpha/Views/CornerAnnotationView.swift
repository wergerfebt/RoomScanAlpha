import SwiftUI
import ARKit
import SceneKit

struct CornerAnnotationView: View {
    let sessionManager: ARSessionManager
    let viewModel: ScanViewModel
    @State private var annotationVM = CornerAnnotationViewModel()
    @State private var scnView: ARSCNView?

    let onDone: (CornerAnnotation?) -> Void
    let onSkip: () -> Void
    let onRedo: () -> Void

    var body: some View {
        ZStack {
            // AR camera feed
            ARAnnotationSceneView(
                sessionManager: sessionManager,
                annotationVM: annotationVM,
                scnViewBinding: $scnView
            )
            .ignoresSafeArea()

            // Center crosshair
            crosshairOverlay

            VStack {
                // Top prompt banner
                promptBanner
                    .padding(.top, 8)

                Spacer()

                // Bottom controls
                controlBar
                    .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Crosshair

    private var crosshairOverlay: some View {
        ZStack {
            // Horizontal line
            Rectangle()
                .fill(Color.white.opacity(0.8))
                .frame(width: 30, height: 1.5)
            // Vertical line
            Rectangle()
                .fill(Color.white.opacity(0.8))
                .frame(width: 1.5, height: 30)
            // Center dot
            Circle()
                .fill(Color.red.opacity(0.9))
                .frame(width: 6, height: 6)
        }
    }

    // MARK: - Prompt Banner

    private var promptBanner: some View {
        Group {
            if annotationVM.isClosed {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Room traced — \(String(format: "%.1f", annotationVM.polygonAreaM2)) m²")
                }
            } else if annotationVM.cornerCount == 0 {
                Text("Aim at each ceiling corner and tap Lock Corner")
            } else {
                Text("\(annotationVM.cornerCount) corner\(annotationVM.cornerCount == 1 ? "" : "s") placed")
            }
        }
        .font(.subheadline)
        .fontWeight(.medium)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        VStack(spacing: 12) {
            if !annotationVM.isClosed {
                // Main action row
                HStack(spacing: 16) {
                    // Undo
                    Button {
                        undoCorner()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .disabled(annotationVM.cornerCount == 0)
                    .opacity(annotationVM.cornerCount == 0 ? 0.4 : 1)

                    // Lock Corner
                    Button {
                        lockCorner()
                    } label: {
                        Label("Lock Corner", systemImage: "scope")
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }

                    // Close Trace
                    Button {
                        annotationVM.closePolygon()
                        updateSceneNodes()
                    } label: {
                        Label("Close", systemImage: "arrow.triangle.turn.up.right.diamond")
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .disabled(!annotationVM.canClose)
                    .opacity(annotationVM.canClose ? 1 : 0.4)
                }
            }

            // Bottom row: Skip / Redo / Done
            HStack(spacing: 20) {
                Button("Skip") {
                    onSkip()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Button("Redo Scan") {
                    onRedo()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if annotationVM.isClosed {
                    Button {
                        onDone(annotationVM.cornerAnnotation)
                    } label: {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .disabled(!annotationVM.canDone)
                    .opacity(annotationVM.canDone ? 1 : 0.4)
                }
            }
        }
    }

    // MARK: - Actions

    private func lockCorner() {
        guard let scnView = scnView else { return }

        // Screen-center point in view coordinates for ARSCNView raycast
        let center = CGPoint(
            x: scnView.bounds.midX,
            y: scnView.bounds.midY
        )

        // Normalized image coordinates (0-1) for ARFrame raycast
        let normalizedCenter = CGPoint(x: 0.5, y: 0.5)

        // Primary: raycast against estimated planes (uses LiDAR depth, no plane detection needed)
        if let query = scnView.session.currentFrame?.raycastQuery(
            from: normalizedCenter,
            allowing: .estimatedPlane,
            alignment: .any
        ) {
            let results = scnView.session.raycast(query)
            if let hit = results.first {
                placeCorner(at: hit.worldTransform, scnView: scnView)
                return
            }
        }

        // Fallback: raycast against the mesh reconstruction directly
        if let query = scnView.session.currentFrame?.raycastQuery(
            from: normalizedCenter,
            allowing: .existingPlaneGeometry,
            alignment: .any
        ) {
            let results = scnView.session.raycast(query)
            if let hit = results.first {
                placeCorner(at: hit.worldTransform, scnView: scnView)
                return
            }
        }

        // Last resort: SceneKit hit test against rendered mesh nodes
        let hits = scnView.hitTest(center, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .boundingBoxOnly: true
        ])
        if let hit = hits.first {
            let worldPos = hit.worldCoordinates
            let snapped = CornerAnnotationViewModel.snapToPlaneIntersection(
                hitPoint: SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z),
                session: sessionManager.session
            )
            annotationVM.addCorner(.init(x: snapped.x, y: snapped.y, z: snapped.z))
            updateSceneNodes()
        }
    }

    private func placeCorner(at worldTransform: simd_float4x4, scnView: ARSCNView) {
        let worldPos = SIMD3<Float>(
            worldTransform.columns.3.x,
            worldTransform.columns.3.y,
            worldTransform.columns.3.z
        )

        let snapped = CornerAnnotationViewModel.snapToPlaneIntersection(
            hitPoint: worldPos,
            session: sessionManager.session
        )

        annotationVM.addCorner(.init(x: snapped.x, y: snapped.y, z: snapped.z))
        updateSceneNodes()
    }

    private func undoCorner() {
        annotationVM.undoLastCorner()
        updateSceneNodes()
    }

    /// Update SceneKit overlay nodes (corner spheres + connecting lines).
    private func updateSceneNodes() {
        guard let scnView = scnView else { return }

        // Remove old annotation nodes
        let annotationTag = "corner_annotation"
        scnView.scene.rootNode.childNodes
            .filter { $0.name?.hasPrefix(annotationTag) == true }
            .forEach { $0.removeFromParentNode() }

        let corners = annotationVM.corners

        // Place corner spheres
        for (i, corner) in corners.enumerated() {
            let sphere = SCNSphere(radius: 0.02)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemYellow
            sphere.materials = [material]

            let node = SCNNode(geometry: sphere)
            node.position = SCNVector3(corner.x, corner.y, corner.z)
            node.name = "\(annotationTag)_sphere_\(i)"

            // Number label
            let text = SCNText(string: "\(i + 1)", extrusionDepth: 0.001)
            text.font = UIFont.systemFont(ofSize: 0.03, weight: .bold)
            text.firstMaterial?.diffuse.contents = UIColor.white
            let textNode = SCNNode(geometry: text)
            textNode.position = SCNVector3(0.025, 0.025, 0)
            textNode.scale = SCNVector3(1, 1, 1)

            // Billboard constraint so label always faces camera
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            textNode.constraints = [billboard]

            node.addChildNode(textNode)
            scnView.scene.rootNode.addChildNode(node)
        }

        // Draw connecting lines
        if corners.count >= 2 {
            let lineCorners = annotationVM.isClosed ? corners + [corners[0]] : corners
            for i in 0..<(lineCorners.count - 1) {
                let from = lineCorners[i]
                let to = lineCorners[i + 1]
                let lineNode = createLineNode(
                    from: SCNVector3(from.x, from.y, from.z),
                    to: SCNVector3(to.x, to.y, to.z),
                    color: annotationVM.isClosed ? .systemGreen : .systemYellow
                )
                lineNode.name = "\(annotationTag)_line_\(i)"
                scnView.scene.rootNode.addChildNode(lineNode)
            }
        }

        // Semi-transparent polygon fill when closed with ≥ 3 corners
        if annotationVM.isClosed, corners.count >= 3 {
            if let fillNode = createPolygonFillNode(corners: corners) {
                fillNode.name = "\(annotationTag)_fill"
                scnView.scene.rootNode.addChildNode(fillNode)
            }
        }
    }

    private func createLineNode(from: SCNVector3, to: SCNVector3, color: UIColor) -> SCNNode {
        let vertices = [from, to]
        let source = SCNGeometrySource(vertices: vertices)
        let indices: [UInt16] = [0, 1]
        let data = Data(bytes: indices, count: indices.count * MemoryLayout<UInt16>.size)
        let element = SCNGeometryElement(
            data: data,
            primitiveType: .line,
            primitiveCount: 1,
            bytesPerIndex: MemoryLayout<UInt16>.size
        )
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.isDoubleSided = true
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private func createPolygonFillNode(corners: [CornerAnnotationViewModel.Corner]) -> SCNNode? {
        guard corners.count >= 3 else { return nil }

        // Average Y for the fill plane
        let avgY = corners.map(\.y).reduce(0, +) / Float(corners.count)

        // Fan triangulation from first vertex
        var vertices: [SCNVector3] = []
        var indices: [UInt16] = []

        for corner in corners {
            vertices.append(SCNVector3(corner.x, avgY, corner.z))
        }

        for i in 1..<(corners.count - 1) {
            indices.append(0)
            indices.append(UInt16(i))
            indices.append(UInt16(i + 1))
        }

        let source = SCNGeometrySource(vertices: vertices)
        let data = Data(bytes: indices, count: indices.count * MemoryLayout<UInt16>.size)
        let element = SCNGeometryElement(
            data: data,
            primitiveType: .triangles,
            primitiveCount: corners.count - 2,
            bytesPerIndex: MemoryLayout<UInt16>.size
        )
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.2)
        material.isDoubleSided = true
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}

// MARK: - AR Scene View (UIViewRepresentable)

/// Wraps ARSCNView for the annotation phase. Reuses the existing AR session
/// so mesh reconstruction continues while the user traces corners.
private struct ARAnnotationSceneView: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let annotationVM: CornerAnnotationViewModel
    @Binding var scnViewBinding: ARSCNView?

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView()
        scnView.session = sessionManager.session
        scnView.delegate = context.coordinator
        scnView.automaticallyUpdatesLighting = true
        scnView.rendersContinuously = true

        DispatchQueue.main.async {
            scnViewBinding = scnView
        }

        return scnView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        /// Cache geometry signature per anchor to skip rebuilds when unchanged.
        private var anchorGeometryCache: [UUID: (vertices: Int, faces: Int)] = [:]

        /// Render every 4th face — annotation wireframe is just spatial context.
        private static let wireframeStride = 4

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
            let node = SCNNode()
            node.addChildNode(buildMeshNode(for: meshAnchor))
            anchorGeometryCache[meshAnchor.identifier] = (
                vertices: meshAnchor.geometry.vertices.count,
                faces: meshAnchor.geometry.faces.count
            )
            return node
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            let newVerts = meshAnchor.geometry.vertices.count
            let newFaces = meshAnchor.geometry.faces.count
            if let cached = anchorGeometryCache[meshAnchor.identifier],
               cached.vertices == newVerts && cached.faces == newFaces {
                return
            }
            node.childNodes.forEach { $0.removeFromParentNode() }
            node.addChildNode(buildMeshNode(for: meshAnchor))
            anchorGeometryCache[meshAnchor.identifier] = (vertices: newVerts, faces: newFaces)
        }

        func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            anchorGeometryCache.removeValue(forKey: meshAnchor.identifier)
        }

        private func buildMeshNode(for meshAnchor: ARMeshAnchor) -> SCNNode {
            let geometry = MeshExtractor.buildLocalSCNGeometry(from: meshAnchor, faceStride: Self.wireframeStride)
            let material = SCNMaterial()
            material.fillMode = .lines
            material.diffuse.contents = UIColor.white.withAlphaComponent(0.15)
            material.isDoubleSided = true
            geometry.materials = [material]
            return SCNNode(geometry: geometry)
        }
    }
}
