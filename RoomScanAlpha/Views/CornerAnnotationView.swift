import SwiftUI
import ARKit
import SceneKit

struct CornerAnnotationView: View {
    let sessionManager: ARSessionManager
    let viewModel: ScanViewModel
    @State private var annotationVM = CornerAnnotationViewModel()
    @State private var scnView: ARSCNView?
    @State private var showTutorial: Bool = !UserDefaults.standard.bool(forKey: "hasSeenCornerTutorial")

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
            .dynamicTypeSize(.large ... .accessibility2)
        }
        .sheet(isPresented: $showTutorial) {
            CornerTracingTutorialOverlay(
                onDismiss: {
                    showTutorial = false
                    UserDefaults.standard.set(true, forKey: "hasSeenCornerTutorial")
                }
            )
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
        HStack(alignment: .top, spacing: 10) {
            Group {
                if annotationVM.isClosed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if annotationVM.canClose {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.blue)
                } else {
                    Image(systemName: "scope")
                        .foregroundStyle(.white)
                }
            }
            .font(.title3)

            Text(bannerText)
                .font(.headline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showTutorial = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .accessibilityLabel("Show corner-tracing tutorial")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    private var finishRoomTint: Color {
        if annotationVM.cornerCount >= 4 { return .green }
        if annotationVM.cornerCount == 3 { return .blue }
        return .gray
    }

    private var finishRoomAccessibility: String {
        if annotationVM.cornerCount >= 4 {
            return "Finish room — close the polygon"
        }
        if annotationVM.cornerCount == 3 {
            return "Finish room as a triangle, or add another corner"
        }
        return "Finish room — add at least 3 corners first"
    }

    private var bannerText: String {
        if annotationVM.isClosed {
            return "Room traced — \(String(format: "%.1f", annotationVM.polygonAreaM2)) m². Tap Done to continue."
        }
        switch annotationVM.cornerCount {
        case 0:
            return "Point at a ceiling corner, then tap Add Corner."
        case 1, 2:
            let noun = annotationVM.cornerCount == 1 ? "corner" : "corners"
            return "\(annotationVM.cornerCount) \(noun) added — keep going until every wall is traced."
        case 3:
            return "3 corners added — tap Finish Room when you've traced every wall. Add more for an L-shape or larger room."
        default:
            return "\(annotationVM.cornerCount) corners added — tap Finish Room to close the shape."
        }
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        VStack(spacing: 14) {
            if annotationVM.isClosed {
                // Closed polygon: offer the Done action prominently.
                Button {
                    onDone(annotationVM.cornerAnnotation)
                } label: {
                    Label("Done", systemImage: "checkmark.circle.fill")
                }
                .largeCapsuleButton(role: .primary, tint: .green)
                .disabled(!annotationVM.canDone)
                .opacity(annotationVM.canDone ? 1 : 0.5)
                .accessibilityLabel("Done — continue to room naming")
                .padding(.horizontal, 24)
            } else {
                // Fixed layout: Finish Room always in the primary slot, Add Corner
                // always in the secondary row. Finish Room's color tiers by corner
                // count (grey <3, blue =3 rare triangle, green ≥4 normal room).
                Button {
                    annotationVM.closePolygon()
                    updateSceneNodes()
                } label: {
                    Label("Finish Room", systemImage: "checkmark.seal.fill")
                }
                .largeCapsuleButton(role: .primary, tint: finishRoomTint)
                .disabled(!annotationVM.canClose)
                .opacity(annotationVM.canClose ? 1 : 0.55)
                .accessibilityLabel(finishRoomAccessibility)
                .padding(.horizontal, 24)

                HStack(spacing: 12) {
                    Button {
                        undoCorner()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .largeCapsuleButton(role: .secondary)
                    .disabled(annotationVM.cornerCount == 0)
                    .opacity(annotationVM.cornerCount == 0 ? 0.5 : 1)
                    .accessibilityLabel("Remove last corner")

                    Button {
                        lockCorner()
                    } label: {
                        Label("Add Corner", systemImage: "scope")
                            .frame(maxWidth: .infinity)
                    }
                    .largeCapsuleButton(role: .secondary, tint: .yellow)
                    .accessibilityLabel("Add corner at crosshair")
                }
                .padding(.horizontal, 24)
            }

            // Footer: Skip / Start Over
            HStack(spacing: 20) {
                Button("Skip corner tracing") { onSkip() }
                    .largeCapsuleButton(role: .tertiary)

                Button("Start Over") { onRedo() }
                    .largeCapsuleButton(role: .tertiary)
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
            let sphere = SCNSphere(radius: 0.04)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemYellow
            sphere.materials = [material]

            let node = SCNNode(geometry: sphere)
            node.position = SCNVector3(corner.x, corner.y, corner.z)
            node.name = "\(annotationTag)_sphere_\(i)"

            // Number label — larger font + dark outline plane for contrast.
            let text = SCNText(string: "\(i + 1)", extrusionDepth: 0.001)
            text.font = UIFont.systemFont(ofSize: 0.06, weight: .bold)
            let labelMat = SCNMaterial()
            labelMat.diffuse.contents = UIColor.white
            labelMat.emission.contents = UIColor.white
            text.firstMaterial = labelMat
            let textNode = SCNNode(geometry: text)
            textNode.position = SCNVector3(0.05, 0.05, 0)

            // Billboard constraint so label always faces camera.
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            textNode.constraints = [billboard]

            node.addChildNode(textNode)

            // Brief pulse on placement — only the most recently added corner.
            if i == corners.count - 1 {
                let pulse = SCNAction.sequence([
                    SCNAction.scale(to: 1.4, duration: 0.12),
                    SCNAction.scale(to: 1.0, duration: 0.18)
                ])
                node.runAction(pulse)
            }

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
