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

/// Renders a PLY mesh downloaded from a signed URL.
struct RemoteMeshViewerView: UIViewRepresentable {
    let meshUrl: URL
    @Binding var isLoading: Bool
    @Binding var loadError: String?

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = .systemBackground
        scnView.scene = SCNScene()

        // Add ambient light immediately
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 500
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scnView.scene?.rootNode.addChildNode(ambientNode)

        // Download and parse PLY on background thread
        Task.detached {
            do {
                let (data, _) = try await URLSession.shared.data(from: meshUrl)
                let geometry = try PLYParser.parse(data: data)

                let material = SCNMaterial()
                material.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.6)
                material.isDoubleSided = true
                geometry.materials = [material]

                let node = SCNNode(geometry: geometry)

                await MainActor.run {
                    scnView.scene?.rootNode.addChildNode(node)
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

// MARK: - PLY Parser (binary PLY → SCNGeometry)

enum PLYParser {
    enum PLYError: Error, LocalizedError {
        case invalidHeader
        case missingCounts
        case dataTooShort

        var errorDescription: String? {
            switch self {
            case .invalidHeader: return "Invalid PLY header"
            case .missingCounts: return "Missing vertex/face counts in PLY"
            case .dataTooShort: return "PLY data is truncated"
            }
        }
    }

    /// Parse a binary little-endian PLY file into SCNGeometry.
    /// Expects the standard format: 6 float32 per vertex (x,y,z,nx,ny,nz),
    /// 1 uint8 count + 3 uint32 indices per face.
    static func parse(data: Data) throws -> SCNGeometry {
        // Find end_header
        guard let headerEnd = data.range(of: Data("end_header\n".utf8)) else {
            throw PLYError.invalidHeader
        }
        let headerStr = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .ascii) ?? ""
        guard headerStr.hasPrefix("ply") else { throw PLYError.invalidHeader }

        var vertexCount: Int?
        var faceCount: Int?
        for line in headerStr.split(separator: "\n") {
            if line.hasPrefix("element vertex") {
                vertexCount = Int(line.split(separator: " ").last ?? "")
            } else if line.hasPrefix("element face") {
                faceCount = Int(line.split(separator: " ").last ?? "")
            }
        }
        guard let vc = vertexCount, let fc = faceCount else { throw PLYError.missingCounts }

        let bodyStart = headerEnd.upperBound
        let vertexBytes = vc * 24 // 6 × float32
        let faceBytes = fc * 13   // 1 × uint8 + 3 × uint32
        guard data.count >= bodyStart + vertexBytes + faceBytes else { throw PLYError.dataTooShort }

        // Parse vertices
        var vertices = [SCNVector3]()
        var normals = [SCNVector3]()
        vertices.reserveCapacity(vc)
        normals.reserveCapacity(vc)

        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: bodyStart)
            for i in 0..<vc {
                let ptr = base.advanced(by: i * 24).assumingMemoryBound(to: Float.self)
                vertices.append(SCNVector3(ptr[0], ptr[1], ptr[2]))
                normals.append(SCNVector3(ptr[3], ptr[4], ptr[5]))
            }
        }

        // Parse faces
        var indices = [UInt32]()
        indices.reserveCapacity(fc * 3)

        data.withUnsafeBytes { raw in
            var offset = bodyStart + vertexBytes
            for _ in 0..<fc {
                let count = raw.load(fromByteOffset: offset, as: UInt8.self)
                offset += 1
                for j in 0..<Int(min(count, 3)) {
                    indices.append(raw.load(fromByteOffset: offset + j * 4, as: UInt32.self))
                }
                offset += Int(count) * 4
            }
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

        return SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
    }
}

struct MeshViewerSheet: View {
    let meshAnchors: [ARMeshAnchor]
    var meshUrl: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        NavigationView {
            ZStack {
                if !meshAnchors.isEmpty {
                    MeshViewerView(meshAnchors: meshAnchors)
                        .ignoresSafeArea(edges: .bottom)
                } else if let url = meshUrl {
                    RemoteMeshViewerView(meshUrl: url, isLoading: $isLoading, loadError: $loadError)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    Text("No mesh data available")
                        .foregroundStyle(.secondary)
                }

                if isLoading && meshAnchors.isEmpty && meshUrl != nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading 3D mesh...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("Failed to load mesh")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
