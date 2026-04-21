import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @State private var viewModel = ScanViewModel()
    @State private var sessionManager = ARSessionManager()
    @State private var isAuthenticated = false

    // Root-level sheets (presented from Home).
    @State private var showSearch = false
    @State private var showInbox = false
    @State private var showAccount = false
    @State private var showWorkspace = false
    @State private var workspaceOrgName: String?


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
                RFQSelectionView(
                    selectedRFQ: $viewModel.selectedRFQ,
                    onScanRoom: { rfq in
                        viewModel.selectedRFQ = rfq
                        viewModel.state = .projectOverview
                    },
                    onClose: {
                        viewModel.state = .idle
                    }
                )
                .onChange(of: viewModel.selectedRFQ) { _, newValue in
                    // Selecting a project (e.g. just-created) should still
                    // advance the state machine. Scan-room from detail has
                    // already advanced, so this branch only fires for new
                    // RFQ creation.
                    if newValue != nil && viewModel.state == .selectingRFQ {
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
                        // Return to scanReady so the user sees the Start Scan button
                        // again. Session is still running; resumeSession() preserves
                        // the world coordinate system and existing HEVC capture.
                        //
                        // Intentionally DO NOT clear localHoles / localUncoveredFaces /
                        // localUncoveredCount — those stay visible as AR markers during
                        // the re-scan so the user can walk toward each gap. The next
                        // analyzer run (after stop-scan) overwrites them.
                        viewModel.uncoveredFaces = [:]
                        viewModel.coverageRatio = 0
                        viewModel.isAnalyzingCoverage = false
                        viewModel.isResumingFromCoverage = true
                        viewModel.state = .scanReady
                    },
                    onLooksGood: {
                        // Session is still running (never paused), so annotation has live AR
                        viewModel.state = .annotatingCorners
                    }
                )
            case .capturingPanorama:
                // Deprecated: panorama replaced by denser walk-around capture
                EmptyView()
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
        // Pre-create sidecar files so the first AR frame only needs AVAssetWriter init.
        sessionManager.frameCaptureManager.videoWriter.prewarm()
        sessionManager.isCapturing = true
        viewModel.startScan()
    }

    private func handleStopScan() {
        sessionManager.isCapturing = false
        // Snapshot mesh but do NOT pause — session stays running through coverage
        // review and annotation (pausing between capture + export causes 1-2ft
        // texture misalignment on resume).
        sessionManager.snapshotMeshAnchors()

        guard viewModel.useInlineCoverageReview else {
            viewModel.state = .annotatingCorners
            return
        }

        // Kick off on-device coverage analysis. State flips to reviewingCoverage
        // immediately so the user sees the loading UI; analyzer populates the
        // ViewModel when it finishes (~2-5s on A15).
        let meshAnchors = sessionManager.lastMeshAnchors
        let poses = sessionManager.frameCaptureManager.poseSamples
        viewModel.isAnalyzingCoverage = true
        viewModel.coverageRatio = 0
        viewModel.localUncoveredFaces = []
        viewModel.localUncoveredCount = 0
        viewModel.state = .reviewingCoverage

        MeshCoverageAnalyzer.analyze(
            meshAnchors: meshAnchors,
            poseSamples: poses
        ) { result in
            viewModel.coverageRatio = result.coverageRatio
            viewModel.uncoveredFaces = result.uncoveredFaces
            viewModel.localUncoveredCount = result.uncoveredCount
            viewModel.localUncoveredFaces = MeshCoverageAnalyzer.buildUncoveredFaces(
                result: result,
                meshAnchors: meshAnchors
            )
            viewModel.enclosureCompleteness = result.enclosureCompleteness
            viewModel.missingEnclosureDirections = result.enclosureDirections
                .filter { !$0.value }
                .map { $0.key }
            viewModel.hasEnoughCameraMotion = result.hasEnoughCameraMotion
            viewModel.localHoles = result.holes
            viewModel.isAnalyzingCoverage = false
            print("[RoomScanAlpha] Inline coverage: \(Int(result.coverageRatio * 100))% texture, \(result.holes.count) holes, motion=\(result.hasEnoughCameraMotion)")
        }
    }

    private func handleRedoScan() {
        sessionManager.resetSession()
        viewModel.redoScan()
    }

    // MARK: - Annotation Handlers

    private func handleAnnotationDone(annotation: CornerAnnotation?) {
        viewModel.cornerAnnotation = annotation
        sessionManager.snapshotMeshAnchors()
        pauseAndAdvance()
    }

    private func handleAnnotationSkip() {
        viewModel.cornerAnnotation = nil
        sessionManager.snapshotMeshAnchors()
        pauseAndAdvance()
    }

    /// Advance to labeling immediately, then pause AR + save world map in background.
    /// Both session.pause() and world map archival are heavy operations that block the
    /// main thread and prevent the keyboard from appearing.
    private func pauseAndAdvance() {
        advanceToLabelingOrWarning()
        DispatchQueue.global(qos: .userInitiated).async {
            sessionManager.pauseSession()
        }
        saveWorldMapInBackground()
    }

    // Cloud-side coverage check + gap-rescan flow removed — on-device coverage
    // review (see `CoverageReviewView`) handles all gap detection pre-upload.

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

        let captureManager = sessionManager.frameCaptureManager
        let meshAnchors = sessionManager.lastMeshAnchors
        let duration = viewModel.scanDuration
        let rfqContext = viewModel.rfqContext
        let cornerAnnotation = viewModel.cornerAnnotation
        let roomScope = viewModel.roomScope
        Task.detached {
            do {
                // Finalize the HEVC video + sidecar files before packaging.
                guard let captureResult = await captureManager.finalizeCapture() else {
                    throw ScanPackager.PackageError.captureFinalizationFailed
                }

                let result = try ScanPackager.package(
                    captureResult: captureResult,
                    meshAnchors: meshAnchors,
                    scanDuration: duration,
                    rfqContext: rfqContext,
                    cornerAnnotation: cornerAnnotation,
                    roomScope: roomScope,
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

                if result.status == "metrics_ready" {
                    // Two-phase pipeline fallback: keep polling until texturing completes.
                    print("[RoomScanAlpha] metrics_ready — continuing to poll for complete...")
                    do {
                        let finalResult = try await CloudUploader.shared.pollForComplete(
                            scanId: scanId, rfqId: rfqId
                        )
                        viewModel.scanResult = finalResult
                        viewModel.saveToHistory(scanId: scanId, status: finalResult.status)
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
        HomeView(
            onStartScan: { latest in
                if let latest = latest {
                    viewModel.selectedRFQ = latest
                    viewModel.state = .projectOverview
                } else {
                    viewModel.state = .selectingRFQ
                }
            },
            onPickProject: {
                viewModel.state = .selectingRFQ
            },
            onOpenProjects: {
                viewModel.state = .selectingRFQ
            },
            onOpenAccount: { showAccount = true },
            onOpenSearch: { showSearch = true },
            onOpenInbox: { showInbox = true },
            onOpenHistory: {
                viewModel.showHistory = true
            },
            onOpenWorkspace: {
                showWorkspace = true
            },
            onSignOut: {
                try? AuthManager.shared.signOut()
                isAuthenticated = false
            }
        )
        .sheet(isPresented: $viewModel.showHistory) {
            ScanHistoryView()
        }
        .sheet(isPresented: $showSearch) {
            SearchView { showSearch = false }
        }
        .sheet(isPresented: $showInbox) {
            InboxView { showInbox = false }
        }
        .sheet(isPresented: $showAccount) {
            AccountView { showAccount = false }
        }
        .sheet(isPresented: $showWorkspace) {
            WorkspaceView(orgName: workspaceOrgName) { showWorkspace = false }
        }
    }

}

#Preview {
    ContentView()
}
