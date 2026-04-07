import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @State private var viewModel = ScanViewModel()
    @State private var sessionManager = ARSessionManager()
    @State private var isAuthenticated = false

    private let hasLiDAR = DeviceCapability.supportsLiDAR
    private let hasARKit = DeviceCapability.supportsARKit

    var body: some View {
        if !isAuthenticated {
            SignInView {
                isAuthenticated = true
            }
        } else {
            scanFlowView
        }
    }

    private var scanFlowView: some View {
        Group {
            switch viewModel.state {
            case .idle:
                idleView
            case .selectingRFQ:
                RFQSelectionView(selectedRFQ: $viewModel.selectedRFQ)
                    .onChange(of: viewModel.selectedRFQ) { _, newValue in
                        if newValue != nil {
                            viewModel.state = .projectOverview
                        }
                    }
            case .projectOverview:
                if let rfq = viewModel.selectedRFQ {
                    ProjectOverviewView(
                        rfq: rfq,
                        onScanRoom: { viewModel.prepareScan() },
                        onBack: { viewModel.returnToIdle() }
                    )
                }
            case .scanReady, .scanning:
                ScanningView(
                    sessionManager: sessionManager,
                    viewModel: viewModel,
                    onStart: { handleStartScan() },
                    onStop: { handleStopScan() },
                    onRedo: { handleRedoScan() }
                )
            case .reviewingCoverage:
                CoverageReviewView(
                    sessionManager: sessionManager,
                    viewModel: viewModel,
                    onContinueScanning: {
                        // Return to scan-ready so user presses "Start Scan" to resume
                        viewModel.uncoveredFaces = [:]
                        viewModel.coverageRatio = 0
                        viewModel.isAnalyzingCoverage = false
                        viewModel.isResumingFromCoverage = true
                        viewModel.state = .scanReady
                    },
                    onLooksGood: {
                        // Frame selection already ran during handleStopScan — proceed directly
                        // Session is still running (never paused), so annotation has live AR
                        viewModel.state = .annotatingCorners
                    }
                )
            case .capturingPanorama:
                // Deprecated: panorama replaced by denser walk-around capture
                EmptyView()
            case .relocalizingForRescan:
                RelocalizationView(
                    sessionManager: sessionManager,
                    onRelocalized: {
                        viewModel.state = .rescanningGaps
                    },
                    onCancel: {
                        sessionManager.pauseSession()
                        viewModel.state = .viewingResults
                    }
                )
            case .rescanningGaps:
                GapRescanView(
                    sessionManager: sessionManager,
                    viewModel: viewModel,
                    uncoveredFaces: viewModel.cloudCoverageResult?.uncoveredFaces ?? [],
                    holeFaces: viewModel.cloudCoverageResult?.holeFaces ?? [],
                    onStop: { handleStopRescan() }
                )
            case .annotatingCorners:
                CornerAnnotationView(
                    sessionManager: sessionManager,
                    viewModel: viewModel,
                    onDone: { annotation in
                        handleAnnotationDone(annotation: annotation)
                    },
                    onSkip: {
                        handleAnnotationSkip()
                    },
                    onRedo: {
                        handleRedoScan()
                    }
                )
            case .labelingRoom:
                RoomLabelView(roomLabel: $viewModel.roomLabel) {
                    if let frame = sessionManager.session.currentFrame {
                        viewModel.buildRFQContext(worldTransform: frame.camera.transform)
                    } else {
                        viewModel.buildRFQContext(worldTransform: .init(1))
                    }
                    if viewModel.hasEnoughStorage {
                        startExport()
                    }  else {
                        viewModel.showLowStorageAlert = true
                    }
                }
            case .exporting:
                ExportingView(viewModel: viewModel, onDone: { viewModel.returnToIdle() })
            case .uploading:
                uploadingView
            case .viewingResults:
                ScanResultView(
                    viewModel: viewModel,
                    meshAnchors: sessionManager.lastMeshAnchors,
                    onDone: {
                        // Return to project overview to see all rooms
                        viewModel.state = .projectOverview
                    },
                    onScanAnother: {
                        // Keep same RFQ, go to scanReady for another room
                        viewModel.prepareScan()
                    },
                    onRescanGaps: {
                        handleRescanGaps()
                    }
                )
            }
        }
        .alert("Scan May Be Incomplete", isPresented: $viewModel.showQualityWarning) {
            Button("Export Anyway") { viewModel.state = .labelingRoom }
            Button("Continue Scanning") { viewModel.state = .scanning }
        } message: {
            Text("Only \(viewModel.keyframeCount) keyframes and \(viewModel.meshTriangleCount) triangles captured. For best results, capture at least \(ScanViewModel.minKeyframes) keyframes and \(ScanViewModel.minMeshTriangles) triangles.")
        }
        .alert("Cellular Data Warning", isPresented: $viewModel.showCellularWarning) {
            Button("Upload Anyway") {
                if let url = viewModel.pendingUploadURL {
                    startUpload(scanDirectoryURL: url)
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingUploadURL = nil
            }
        } message: {
            Text("You're on cellular data. This upload is approximately 50-100 MB. Continue?")
        }
        .alert("Scan Interrupted", isPresented: $viewModel.showInterruptionAlert) {
            Button("Resume") { /* AR session auto-resumes */ }
            Button("Stop Scan") { handleStopScan() }
        } message: {
            Text("The scan was interrupted (e.g., phone call). You can resume or stop and save what was captured.")
        }
        .alert("Low Storage", isPresented: $viewModel.showLowStorageAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Not enough storage to export scan. Free up at least 200 MB and try again.")
        }
        .alert("Frame Limit Reached", isPresented: $viewModel.showCapReachedAlert) {
            Button("Stop Scan") { handleStopScan() }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Captured \(viewModel.keyframeCount) frames — the maximum for this scan. Tap Stop Scan to review coverage, or continue walking to build the mesh.")
        }
        .onAppear {
            isAuthenticated = AuthManager.shared.isSignedIn
        }
    }

    // MARK: - Scan Control Handlers

    private func handleStartScan() {
        sessionManager.isCapturing = true
        viewModel.startScan()
    }

    private func handleStopScan() {
        sessionManager.isCapturing = false
        // Snapshot mesh but do NOT pause — session stays running during annotation
        sessionManager.snapshotMeshAnchors()
        // Go straight to annotation (matching original working flow)
        viewModel.state = .annotatingCorners

        // Kick off frame selection in background while user annotates
        sessionManager.frameCaptureManager.selectBestFrames()
    }

    private func handleRedoScan() {
        sessionManager.resetSession()
        viewModel.redoScan()
    }

    // MARK: - Annotation Handlers

    private func handleAnnotationDone(annotation: CornerAnnotation?) {
        viewModel.cornerAnnotation = annotation
        sessionManager.snapshotMeshAnchors()
        // Denser walk-around capture replaces panorama — go straight to labeling
        sessionManager.pauseSession()
        saveWorldMapInBackground()
        waitForFrameSelectionThen {
            advanceToLabelingOrWarning()
        }
    }

    private func handleAnnotationSkip() {
        viewModel.cornerAnnotation = nil
        sessionManager.snapshotMeshAnchors()
        sessionManager.pauseSession()
        saveWorldMapInBackground()
        waitForFrameSelectionThen {
            advanceToLabelingOrWarning()
        }
    }

    private func checkCoverageAutomatically(scanId: String, rfqId: String) {
        viewModel.isCheckingCoverage = true
        viewModel.coverageError = nil

        Task {
            do {
                let result = try await CloudUploader.shared.checkCoverage(scanId: scanId, rfqId: rfqId)
                viewModel.cloudCoverageResult = result
                viewModel.isCheckingCoverage = false
                print("[RoomScanAlpha] Auto coverage check: \(Int(result.coverageRatio * 100))%, \(result.uncoveredCount) gaps")
            } catch {
                viewModel.coverageError = error.localizedDescription
                viewModel.isCheckingCoverage = false
                print("[RoomScanAlpha] Auto coverage check failed: \(error)")
            }
        }
    }

    private func handleStopRescan() {
        sessionManager.isCapturing = false
        sessionManager.snapshotMeshAnchors()
        let supplementalCount = sessionManager.frameCaptureManager.keyframeCount
        sessionManager.pauseSession()
        print("[RoomScanAlpha] Gap rescan stopped — \(supplementalCount) supplemental frames")

        guard supplementalCount > 0 else {
            print("[RoomScanAlpha] No supplemental frames captured — skipping upload")
            viewModel.hasCompletedRescan = true
            viewModel.state = .viewingResults
            return
        }

        // Package and upload supplemental data
        startSupplementalExport()
    }

    private func startSupplementalExport() {
        viewModel.state = .uploading
        viewModel.uploadStatus = "Packaging supplemental scan..."
        viewModel.uploadProgress = 0.0
        viewModel.uploadError = nil

        let keyframes = sessionManager.frameCaptureManager.capturedFrames
        let meshAnchors = sessionManager.lastMeshAnchors

        Task.detached {
            do {
                let result = try ScanPackager.packageSupplemental(
                    keyframes: keyframes,
                    meshAnchors: meshAnchors,
                    onProgress: { message in
                        Task { @MainActor in
                            viewModel.uploadStatus = message
                        }
                    }
                )
                await MainActor.run {
                    let sizeMB = result.totalSizeBytes / 1024 / 1024
                    print("[RoomScanAlpha] Supplemental export: \(sizeMB)MB")
                    startSupplementalUpload(scanDirectoryURL: result.directoryURL)
                }
            } catch {
                await MainActor.run {
                    viewModel.uploadError = error.localizedDescription
                    viewModel.uploadStatus = "Export failed"
                    print("[RoomScanAlpha] Supplemental export error: \(error)")
                }
            }
        }
    }

    private func startSupplementalUpload(scanDirectoryURL: URL) {
        guard let rfqId = viewModel.selectedRFQ?.id,
              let scanId = viewModel.lastScanId else {
            viewModel.uploadError = "Missing RFQ or scan ID"
            viewModel.uploadStatus = "Upload failed"
            return
        }

        viewModel.uploadStatus = "Uploading supplemental scan..."

        Task {
            do {
                _ = try await CloudUploader.shared.uploadSupplemental(
                    scanDirectoryURL: scanDirectoryURL,
                    rfqId: rfqId,
                    scanId: scanId,
                    onProgress: { status, fraction in
                        viewModel.uploadStatus = status
                        viewModel.uploadProgress = fraction
                    }
                )
                viewModel.uploadStatus = "Reprocessing..."
                print("[RoomScanAlpha] Supplemental upload complete — polling for results")

                // Poll for reprocessing completion, then re-check coverage
                startPolling(scanId: scanId, rfqId: rfqId)
            } catch {
                viewModel.uploadError = error.localizedDescription
                viewModel.uploadStatus = "Upload failed"
                viewModel.hasCompletedRescan = true
                viewModel.state = .viewingResults
                print("[RoomScanAlpha] Supplemental upload error: \(error)")
            }
        }
    }

    private func handleRescanGaps() {
        guard let rfqId = viewModel.selectedRFQ?.id else { return }
        let worldMapURL = ARSessionManager.worldMapURL(rfqId: rfqId)

        guard FileManager.default.fileExists(atPath: worldMapURL.path) else {
            print("[RoomScanAlpha] No world map found at \(worldMapURL.path)")
            viewModel.coverageError = "No saved world map — cannot relocalize"
            return
        }

        do {
            try sessionManager.startRelocalized(worldMapURL: worldMapURL)
            viewModel.state = .relocalizingForRescan
            print("[RoomScanAlpha] Starting relocalization from saved world map")
        } catch {
            print("[RoomScanAlpha] Failed to load world map: \(error)")
            viewModel.coverageError = "Failed to load world map: \(error.localizedDescription)"
        }
    }

    /// Save the ARWorldMap to disk after pausing the session.
    /// Runs in background — does not block the scan flow.
    private func saveWorldMapInBackground() {
        guard let rfqId = viewModel.selectedRFQ?.id else { return }
        let url = ARSessionManager.worldMapURL(rfqId: rfqId)
        Task {
            do {
                try await sessionManager.saveWorldMap(to: url)
            } catch {
                print("[RoomScanAlpha] World map save failed: \(error.localizedDescription)")
            }
        }
    }

    /// Wait for post-scan frame selection to finish before calling the continuation.
    private func waitForFrameSelectionThen(then: @escaping () -> Void) {
        let fcm = sessionManager.frameCaptureManager
        if fcm.selectionComplete || !fcm.isSelecting {
            then()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                waitForFrameSelectionThen(then: then)
            }
        }
    }

    private func advanceToLabelingOrWarning() {
        if viewModel.scanQualitySufficient {
            viewModel.state = .labelingRoom
        } else {
            viewModel.showQualityWarning = true
        }
    }

    /// Package the captured scan data and begin the upload flow.
    ///
    /// Flow: export on background thread → check network → either upload (Wi-Fi),
    /// prompt for cellular confirmation, or show error (no connection).
    private func startExport() {
        viewModel.state = .exporting
        viewModel.exportProgress = "Preparing export..."

        let keyframes = sessionManager.frameCaptureManager.capturedFrames
        let meshAnchors = sessionManager.lastMeshAnchors
        let duration = viewModel.scanDuration
        let rfqContext = viewModel.rfqContext
        let cornerAnnotation = viewModel.cornerAnnotation
        let roomScope = viewModel.roomScope
        let panoramicFrames = sessionManager.panoramicFrames
        let panoramaStartTransform = viewModel.panoramaStartTransform

        Task.detached {
            do {
                let result = try ScanPackager.package(
                    keyframes: keyframes,
                    meshAnchors: meshAnchors,
                    scanDuration: duration,
                    rfqContext: rfqContext,
                    cornerAnnotation: cornerAnnotation,
                    roomScope: roomScope,
                    panoramicFrames: panoramicFrames,
                    panoramaStartTransform: panoramaStartTransform,
                    onProgress: { message in
                        Task { @MainActor in
                            viewModel.exportProgress = message
                        }
                    }
                )
                // Check network before touching UI state
                let network = await CloudUploader.shared.checkNetwork()

                await MainActor.run {
                    viewModel.lastExportURL = result.directoryURL
                    let sizeMB = result.totalSizeBytes / 1024 / 1024
                    viewModel.exportProgress = "Export complete — \(sizeMB)MB"
                    print("[RoomScanAlpha] Export complete: \(result.directoryURL.path)")

                    // Gate upload on network availability: proceed on Wi-Fi, warn on cellular,
                    // or show error if offline.
                    if !network.connected {
                        viewModel.uploadError = "No network connection"
                        viewModel.uploadStatus = "Upload failed"
                        viewModel.state = .uploading
                    } else if network.cellular {
                        viewModel.pendingUploadURL = result.directoryURL
                        viewModel.showCellularWarning = true
                    } else {
                        startUpload(scanDirectoryURL: result.directoryURL)
                    }
                }
            } catch {
                await MainActor.run {
                    viewModel.exportError = error.localizedDescription
                    viewModel.exportProgress = "Export failed"
                    print("[RoomScanAlpha] Export error: \(error)")
                }
            }
        }
    }

    private func startUpload(scanDirectoryURL: URL) {
        guard let rfqId = viewModel.selectedRFQ?.id else {
            viewModel.uploadError = "No RFQ selected"
            return
        }

        viewModel.state = .uploading
        viewModel.uploadStatus = "Starting upload..."
        viewModel.uploadProgress = 0.0

        Task {
            do {
                let result = try await CloudUploader.shared.upload(
                    scanDirectoryURL: scanDirectoryURL,
                    rfqId: rfqId,
                    roomLabel: viewModel.roomLabel,
                    onProgress: { status, fraction in
                        viewModel.uploadStatus = status
                        viewModel.uploadProgress = fraction
                    }
                )
                viewModel.lastScanId = result.scanId
                viewModel.uploadStatus = "Upload complete"
                print("[RoomScanAlpha] Upload complete — scan ID: \(result.scanId)")
                startPolling(scanId: result.scanId, rfqId: rfqId)
            } catch {
                viewModel.uploadError = error.localizedDescription
                viewModel.uploadStatus = "Upload failed"
                print("[RoomScanAlpha] Upload error: \(error)")
            }
        }
    }

    /// Poll the backend for scan processing results. On failure, we still show the result
    /// view with a "failed" status so the user can see something went wrong and retry,
    /// rather than being stuck on a loading screen.
    /// Poll until scan processing completes (~30-40s). The processor now does
    /// metrics + preview texture + inline coverage in a single pass, writing "complete".
    /// If inline coverage is available in the response, use it directly (no /coverage call).
    private func startPolling(scanId: String, rfqId: String) {
        viewModel.state = .viewingResults

        Task {
            do {
                let result = try await CloudUploader.shared.pollForResult(scanId: scanId, rfqId: rfqId)
                viewModel.scanResult = result
                viewModel.saveToHistory(scanId: scanId, status: result.status)
                print("[RoomScanAlpha] Scan result: \(result.status)")

                if result.status == "complete" || result.status == "scan_ready" {
                    // Use inline coverage if available (no separate /coverage call needed)
                    if let inlineCov = result.inlineCoverage {
                        viewModel.cloudCoverageResult = inlineCov
                        print("[RoomScanAlpha] Inline coverage: \(Int(inlineCov.coverageRatio * 100))%")
                    } else {
                        // Fallback: call /coverage endpoint (old processor without inline coverage)
                        checkCoverageAutomatically(scanId: scanId, rfqId: rfqId)
                    }
                } else if result.status == "metrics_ready" {
                    // Legacy: two-phase pipeline fallback. Show fast results, keep polling.
                    print("[RoomScanAlpha] metrics_ready — continuing to poll for complete...")
                    do {
                        let finalResult = try await CloudUploader.shared.pollForComplete(
                            scanId: scanId, rfqId: rfqId
                        )
                        viewModel.scanResult = finalResult
                        viewModel.saveToHistory(scanId: scanId, status: finalResult.status)
                        if let inlineCov = finalResult.inlineCoverage {
                            viewModel.cloudCoverageResult = inlineCov
                        } else {
                            checkCoverageAutomatically(scanId: scanId, rfqId: rfqId)
                        }
                    } catch {
                        print("[RoomScanAlpha] Phase 2 polling timed out: \(error)")
                    }
                }
            } catch {
                viewModel.saveToHistory(scanId: scanId, status: "failed")
                viewModel.scanResult = CloudUploader.ScanResult(
                    scanId: scanId,
                    status: "failed",
                    floorAreaSqft: nil,
                    wallAreaSqft: nil,
                    ceilingHeightFt: nil,
                    perimeterLinearFt: nil,
                    detectedComponents: nil,
                    scanDimensions: nil,
                    roomPolygonFt: nil,
                    wallHeightsFt: nil,
                    polygonSource: nil,
                    scanMeshUrl: nil,
                    fastCoverage: nil,
                    inlineCoverage: nil
                )
                print("[RoomScanAlpha] Polling error: \(error)")
            }
        }
    }

    // MARK: - Uploading View

    private var uploadingView: some View {
        VStack(spacing: 24) {
            Spacer()

            if viewModel.lastScanId != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
            } else if viewModel.uploadError != nil {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)
            } else {
                VStack(spacing: 16) {
                    ProgressView(value: viewModel.uploadProgress)
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 60)

                    Text("\(Int(viewModel.uploadProgress * 100))%")
                        .font(.system(.title2, design: .monospaced))
                        .fontWeight(.semibold)
                }
            }

            Text(viewModel.uploadStatus)
                .font(.headline)
                .multilineTextAlignment(.center)

            if let error = viewModel.uploadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            if viewModel.lastScanId != nil || viewModel.uploadError != nil {
                Button {
                    viewModel.returnToIdle()
                } label: {
                    Label("Done", systemImage: "house")
                        .primaryButtonStyle()
                }
                .padding(.horizontal, 40)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Idle View

    private var idleView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: hasLiDAR ? "camera.viewfinder" : "exclamationmark.triangle")
                .font(.system(size: 64))
                .foregroundStyle(hasLiDAR ? .blue : .orange)

            HStack {
                Text("RoomScan Alpha")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Spacer()
                Button {
                    viewModel.showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                }
                Button {
                    try? AuthManager.shared.signOut()
                    isAuthenticated = false
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)

            if hasLiDAR {
                if let rfq = viewModel.selectedRFQ {
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.blue)
                        Text(rfq.displayTitle)
                            .font(.subheadline)
                        Spacer()
                        Button("Change") {
                            viewModel.state = .selectingRFQ
                        }
                        .font(.caption)
                    }
                    .padding(.horizontal, 40)
                }

                Button {
                    if viewModel.hasRFQSelected {
                        viewModel.state = .projectOverview
                    } else {
                        viewModel.state = .selectingRFQ
                    }
                } label: {
                    Label(
                        viewModel.hasRFQSelected ? "View Project" : "Select Project to Scan",
                        systemImage: viewModel.hasRFQSelected ? "doc.text.magnifyingglass" : "doc.text.magnifyingglass"
                    )
                    .primaryButtonStyle()
                }
                .padding(.horizontal, 40)
                .padding(.top, 8)
            } else {
                VStack(spacing: 12) {
                    Text("This app requires a LiDAR-equipped device")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    capabilityRow(label: "ARKit", supported: hasARKit)
                    capabilityRow(label: "LiDAR Scanner", supported: false)
                }

                Button {} label: {
                    Label("Start Scan", systemImage: "viewfinder")
                        .disabledButtonStyle()
                }
                .disabled(true)
                .padding(.horizontal, 40)
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding()
        .sheet(isPresented: $viewModel.showHistory) {
            ScanHistoryView()
        }
    }

    private func capabilityRow(label: String, supported: Bool) -> some View {
        HStack {
            Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(supported ? .green : .red)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(supported ? "Available" : "Not Available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 40)
    }
}

#Preview {
    ContentView()
}
