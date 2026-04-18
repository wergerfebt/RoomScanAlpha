import SwiftUI
import ARKit

struct ScanResultView: View {
    let viewModel: ScanViewModel
    let meshAnchors: [ARMeshAnchor]
    let onDone: () -> Void
    let onScanAnother: (() -> Void)?

    @State private var showMeshViewer = false
    @State private var showFloorPlan = false
    @State private var showRemoteMesh = false
    @State private var selectedMeshUrl: URL?
    @State private var selectedScopeItems: Set<String> = []
    @State private var scopeNotes: String = ""
    @State private var scopeSaved = false
    @State private var processingMessageIndex: Int = 0
    @State private var processingTimer: Timer?

    private static let processingMessages = [
        "Uploading mesh to processing server...",
        "Reconstructing 3D geometry...",
        "Selecting optimal camera views per face...",
        "Generating texture atlas...",
        "Applying seam leveling corrections...",
        "Computing room dimensions...",
        "Detecting floor and ceiling planes...",
        "Measuring wall segments...",
        "Analyzing room polygon...",
        "Finalizing textured model...",
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 20)

                if let result = viewModel.scanResult {
                    if result.status == "complete" || result.status == "scan_ready" || result.status == "metrics_ready" {
                        readyView(result: result)
                    } else {
                        failedView(result: result)
                    }
                } else {
                    processingView
                }

                if canProceed {
                    footerActions
                        .padding(.bottom, 40)
                }
            }
        }
        .sheet(isPresented: $showMeshViewer) {
            MeshViewerSheet(meshAnchors: meshAnchors)
        }
        .sheet(isPresented: $showFloorPlan) {
            if let polygon = floorPlanPolygon {
                let scanId = viewModel.scanResult?.scanId ?? viewModel.lastScanId ?? "scan"
                let room = FloorPlanRoom(
                    id: scanId,
                    label: viewModel.roomLabel.isEmpty ? "Room" : viewModel.roomLabel,
                    polygonFt: polygon,
                    areaSqft: viewModel.scanResult?.floorAreaSqft ?? floorPlanAreaSqft,
                    scanMeshUrl: viewModel.scanResult?.scanMeshUrl
                )
                FloorPlanSheet(rooms: [room], meshAnchors: meshAnchors) { tapped in
                    showFloorPlan = false
                    if let urlStr = tapped.scanMeshUrl, let url = URL(string: urlStr) {
                        selectedMeshUrl = url
                        showRemoteMesh = true
                    } else if !meshAnchors.isEmpty {
                        showMeshViewer = true
                    }
                }
            }
        }
        .sheet(isPresented: $showRemoteMesh) {
            if let url = selectedMeshUrl {
                MeshViewerSheet(meshAnchors: [], meshUrl: url)
            }
        }
        .dynamicTypeSize(.large ... .accessibility2)
    }

    /// Action buttons (Done, Scan Another, etc.) are hidden only while the scan
    /// is still processing. On-device inline coverage review runs pre-upload
    /// (see `CoverageReviewView`), so cloud coverage is informational here —
    /// it no longer gates progress.
    private var canProceed: Bool {
        // Always let the user proceed once the scan result has landed.
        viewModel.scanResult != nil
    }

    // MARK: - Processing

    private var processingView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 40)

            ProgressView()
                .scaleEffect(2)

            Text("Processing your scan...")
                .font(.headline)

            Text(Self.processingMessages[processingMessageIndex % Self.processingMessages.count])
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .animation(.easeInOut(duration: 0.3), value: processingMessageIndex)

            if let scanId = viewModel.lastScanId {
                Text("Scan ID: \(scanId.prefix(8))...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer().frame(height: 40)
        }
        .onAppear {
            // Guard against double onAppear creating duplicate timers
            processingTimer?.invalidate()
            processingMessageIndex = 0
            processingTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
                processingMessageIndex += 1
            }
        }
        .onDisappear {
            processingTimer?.invalidate()
            processingTimer = nil
        }
    }

    // MARK: - Ready

    private func readyView(result: CloudUploader.ScanResult) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Scan Complete")
                .font(.title2)
                .fontWeight(.bold)

            // Primary action surface — Scope of Work is what the user needs to
            // complete before moving on. Shown first so it's above the fold.
            scopeSelectionView

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

    // MARK: - Footer Actions

    /// Primary "Done" to submit, secondary "Scan Another Room", and tertiary
    /// inline links for the viewers. Scope of Work has already been saved
    /// inline at the top of the screen, so the footer doesn't duplicate it.
    private var footerActions: some View {
        VStack(spacing: 14) {
            Button(action: onDone) {
                Label("Done", systemImage: "checkmark.circle.fill")
            }
            .largeCapsuleButton(role: .primary, tint: .green)
            .padding(.horizontal, 24)

            if let onScanAnother {
                Button(action: onScanAnother) {
                    Label("Scan Another Room", systemImage: "plus.viewfinder")
                }
                .largeCapsuleButton(role: .secondary)
                .padding(.horizontal, 24)
            }

            HStack(spacing: 24) {
                if !meshAnchors.isEmpty {
                    Button {
                        showMeshViewer = true
                    } label: {
                        Label("View 3D Scan", systemImage: "cube")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if floorPlanPolygon != nil {
                    Button {
                        showFloorPlan = true
                    } label: {
                        Label("Floor Plan", systemImage: "square.split.bottomrightquarter")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
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

    // MARK: - Scope of Work

    private var scopeSelectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Scope of Work")

            let items = ScopeItemCatalog.items(for: viewModel.roomLabel)

            FlowLayout(spacing: 6) {
                ForEach(items) { item in
                    Button {
                        if selectedScopeItems.contains(item.id) {
                            selectedScopeItems.remove(item.id)
                        } else {
                            selectedScopeItems.insert(item.id)
                        }
                        scopeSaved = false
                    } label: {
                        Text(item.label)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selectedScopeItems.contains(item.id) ? Color.blue : Color.blue.opacity(0.1))
                            .foregroundStyle(selectedScopeItems.contains(item.id) ? .white : .blue)
                            .clipShape(Capsule())
                    }
                }
            }

            TextField("Notes (optional)", text: $scopeNotes, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .onChange(of: scopeNotes) { _, _ in scopeSaved = false }

            if !selectedScopeItems.isEmpty || !scopeNotes.isEmpty {
                Button {
                    saveScope()
                } label: {
                    Label(
                        scopeSaved ? "Scope Saved" : "Save Scope of Work",
                        systemImage: scopeSaved ? "checkmark.circle.fill" : "square.and.arrow.up"
                    )
                }
                .largeCapsuleButton(role: .primary, tint: scopeSaved ? .green : .blue)
                .disabled(scopeSaved)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
    }

    private func saveScope() {
        guard let rfqId = viewModel.selectedRFQ?.id,
              let scanId = viewModel.lastScanId ?? viewModel.scanResult?.scanId else { return }

        let scope = RoomScope(items: Array(selectedScopeItems), notes: scopeNotes)
        Task {
            do {
                try await RFQService.shared.saveScope(rfqId: rfqId, scanId: scanId, scope: scope)
                scopeSaved = true
                print("[RoomScanAlpha] Scope saved for scan \(scanId)")
            } catch {
                print("[RoomScanAlpha] Failed to save scope: \(error)")
            }
        }
    }

    // MARK: - Floor Plan Data

    private static let mToFt: Double = 3.28084

    /// Polygon in feet: prefer cloud-returned data, fall back to local annotation converted to feet.
    private var floorPlanPolygon: [[Double]]? {
        if let polygon = viewModel.scanResult?.roomPolygonFt, !polygon.isEmpty {
            return polygon
        }
        guard let annotation = viewModel.cornerAnnotation else { return nil }
        guard annotation.corners_xz.count >= 3 else { return nil }
        return annotation.corners_xz.map { corner in
            [Double(corner[0]) * Self.mToFt, Double(corner[1]) * Self.mToFt]
        }
    }

    /// Area in sq ft from local annotation (shoelace on meters, then convert).
    private var floorPlanAreaSqft: Double? {
        guard let annotation = viewModel.cornerAnnotation else { return nil }
        let corners = annotation.corners_xz
        guard corners.count >= 3 else { return nil }
        var sum: Double = 0
        for i in 0..<corners.count {
            let j = (i + 1) % corners.count
            sum += Double(corners[i][0]) * Double(corners[j][1]) - Double(corners[j][0]) * Double(corners[i][1])
        }
        let areaM2 = abs(sum) / 2.0
        return (areaM2 * 10.7639 * 10).rounded() / 10 // sqm → sqft, round to 1 decimal
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
