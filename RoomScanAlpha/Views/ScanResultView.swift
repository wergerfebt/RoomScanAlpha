import SwiftUI
import ARKit

struct ScanResultView: View {
    let viewModel: ScanViewModel
    let meshAnchors: [ARMeshAnchor]
    let onDone: () -> Void
    let onScanAnother: (() -> Void)?

    @State private var showMeshViewer = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 20)

                if let result = viewModel.scanResult {
                    if result.status == "scan_ready" {
                        readyView(result: result)
                    } else {
                        failedView(result: result)
                    }
                } else {
                    processingView
                }

                if !meshAnchors.isEmpty {
                    Button {
                        showMeshViewer = true
                    } label: {
                        Label("View 3D Scan", systemImage: "cube")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 40)
                }

                if let onScanAnother {
                    Button(action: onScanAnother) {
                        Label("Scan Another Room", systemImage: "plus.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.green.opacity(0.1))
                            .foregroundStyle(.green)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 40)
                }

                Button(action: onDone) {
                    Label("Done", systemImage: "house")
                        .primaryButtonStyle()
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showMeshViewer) {
            MeshViewerSheet(meshAnchors: meshAnchors)
        }
    }

    // MARK: - Processing

    private var processingView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 40)

            ProgressView()
                .scaleEffect(2)

            Text("Processing your scan...")
                .font(.headline)

            Text("This usually takes a few seconds")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let scanId = viewModel.lastScanId {
                Text("Scan ID: \(scanId.prefix(8))...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer().frame(height: 40)
        }
    }

    // MARK: - Ready

    private func readyView(result: CloudUploader.ScanResult) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Scan Complete")
                .font(.title2)
                .fontWeight(.bold)

            // Room Dimensions
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Room Dimensions")

                if let area = result.floorAreaSqft {
                    dimensionRow(icon: "square.dashed", label: "Floor Area", value: String(format: "%.0f sq ft", area))
                }
                if let walls = result.wallAreaSqft {
                    dimensionRow(icon: "rectangle.split.3x1", label: "Wall Area", value: String(format: "%.0f sq ft", walls))
                }
                if let ceiling = result.ceilingHeightFt {
                    dimensionRow(icon: "arrow.up.to.line", label: "Ceiling Height", value: String(format: "%.1f ft", ceiling))
                }
                if let perimeter = result.perimeterLinearFt {
                    dimensionRow(icon: "ruler", label: "Perimeter", value: String(format: "%.0f linear ft", perimeter))
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)

            // Scan Dimensions (bounding box) — nested under scan_dimensions.bbox
            if let dims = result.scanDimensions,
               let bbox = dims["bbox"] as? [String: Any],
               let bx = bbox["x_m"] as? Double,
               let by = bbox["y_m"] as? Double,
               let bz = bbox["z_m"] as? Double {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Scan Bounding Box")

                    dimensionRow(icon: "arrow.left.and.right", label: "Width (X)", value: String(format: "%.2f m", bx))
                    dimensionRow(icon: "arrow.up.and.down", label: "Height (Y)", value: String(format: "%.2f m", by))
                    dimensionRow(icon: "arrow.forward", label: "Depth (Z)", value: String(format: "%.2f m", bz))
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
            }

            // Detected Components
            if let components = result.detectedComponents, !components.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Detected Components")

                    FlowLayout(spacing: 8) {
                        ForEach(components, id: \.self) { component in
                            Text(component.capitalized)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
            }

            // Scan stats
            VStack(spacing: 4) {
                Text("\(viewModel.keyframeCount) keyframes  •  \(viewModel.meshTriangleCount) triangles")
                if let scanId = viewModel.lastScanId {
                    Text("Scan ID: \(scanId.prefix(8))...")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Failed

    private func failedView(result: CloudUploader.ScanResult) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)

            Text("Processing Failed")
                .font(.title2)
                .fontWeight(.bold)

            Text("There was an error processing your scan. Please try scanning again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if let scanId = viewModel.lastScanId {
                Text("Scan ID: \(scanId.prefix(8))...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private func dimensionRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .fontWeight(.medium)
        }
    }
}

// Simple flow layout for component tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
