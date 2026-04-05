import SwiftUI
import ARKit

struct ScanResultView: View {
    let viewModel: ScanViewModel
    let meshAnchors: [ARMeshAnchor]
    let onDone: () -> Void
    let onScanAnother: (() -> Void)?
    var onRescanGaps: (() -> Void)?

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
                    if result.status == "complete" || result.status == "scan_ready" {
                        readyView(result: result)
                    } else {
                        failedView(result: result)
                    }
                } else {
                    processingView
                }

                // Action buttons — only shown after coverage is resolved
                if canProceed {
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

                    if floorPlanPolygon != nil {
                        Button {
                            showFloorPlan = true
                        } label: {
                            Label("View Floor Plan", systemImage: "square.split.bottomrightquarter")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(.indigo.opacity(0.1))
                                .foregroundStyle(.indigo)
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
    }

    /// Action buttons (Done, Scan Another, etc.) are hidden until coverage is resolved:
    /// either coverage >= 90%, coverage check failed (let them proceed), or scan processing failed.
    private var canProceed: Bool {
        // User completed a gap re-scan — always let them proceed
        if viewModel.hasCompletedRescan { return true }
        // Failed scans — let user proceed
        if let result = viewModel.scanResult, result.status == "failed" {
            return true
        }
        // Coverage check failed — don't block the user
        if viewModel.coverageError != nil && viewModel.cloudCoverageResult == nil {
            return true
        }
        // Coverage checked and good enough
        if let coverage = viewModel.cloudCoverageResult {
            return coverage.coverageRatio >= 0.90
        }
        // Still processing or checking coverage
        return false
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
            processingTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
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

            // Scope of Work
            scopeSelectionView

            // Coverage Check
            coverageSection

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

    // MARK: - Coverage Check

    private var coverageSection: some View {
        VStack(spacing: 12) {
            if let result = viewModel.cloudCoverageResult {
                // Show coverage result
                let pct = Int(result.coverageRatio * 100)
                HStack {
                    Image(systemName: pct >= 90 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(pct >= 90 ? .green : .orange)
                    Text("\(pct)% Coverage")
                        .font(.headline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(result.uncoveredCount) untextured")
                            .foregroundStyle(.orange)
                        if result.holeCount > 0 {
                            Text("\(result.holeCount) mesh holes")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                }

                if pct < 90, let onRescanGaps {
                    Button(action: onRescanGaps) {
                        Label("Re-scan Gaps", systemImage: "camera.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.orange.opacity(0.1))
                            .foregroundStyle(.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else if viewModel.isCheckingCoverage {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking coverage...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let error = viewModel.coverageError {
                // Coverage check failed — show retry button
                Button {
                    checkCoverage()
                } label: {
                    Label("Retry Coverage Check", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.purple.opacity(0.1))
                        .foregroundStyle(.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                // Error text is shown below via the separate error view
                let _ = error  // suppress unused warning
            }

            if let error = viewModel.coverageError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
    }

    private func checkCoverage() {
        guard let rfqId = viewModel.selectedRFQ?.id,
              let scanId = viewModel.lastScanId ?? viewModel.scanResult?.scanId else { return }

        viewModel.isCheckingCoverage = true
        viewModel.coverageError = nil

        Task {
            do {
                let result = try await CloudUploader.shared.checkCoverage(scanId: scanId, rfqId: rfqId)
                viewModel.cloudCoverageResult = result
                viewModel.isCheckingCoverage = false
                print("[RoomScanAlpha] Coverage check: \(Int(result.coverageRatio * 100))%, \(result.uncoveredCount) gaps")
            } catch {
                viewModel.coverageError = error.localizedDescription
                viewModel.isCheckingCoverage = false
                print("[RoomScanAlpha] Coverage check failed: \(error)")
            }
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
                    HStack {
                        Image(systemName: scopeSaved ? "checkmark.circle.fill" : "square.and.arrow.up")
                        Text(scopeSaved ? "Scope Saved" : "Save Scope")
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(scopeSaved ? .green.opacity(0.1) : .blue.opacity(0.1))
                    .foregroundStyle(scopeSaved ? .green : .blue)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
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
