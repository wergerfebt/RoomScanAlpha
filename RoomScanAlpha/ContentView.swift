import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @State private var viewModel = ScanViewModel()
    @State private var sessionManager = ARSessionManager()
    @State private var isAuthenticated = false

    // Root-level sheets (presented from Home or ContractorHome).
    @State private var showSearch = false
    @State private var showInbox = false
    @State private var showAccount = false

    // Workspace mode: swaps idleView between HomeView (personal) and
    // ContractorHomeView. Fetched once from /api/account and shared with both
    // so the user's org identity is available without re-fetching.
    @State private var workspaceMode = false
    @State private var account: Account?

    // "Create a project" sheet — shown from HomeView when the user taps
    // Start scan or Pick project and has no projects yet.
    @State private var showNewProjectSheet = false

    // Contractor-workspace destination sheets.
    @State private var showJobs = false
    @State private var showGallery = false
    @State private var showTeam = false
    @State private var showServices = false
    @State private var showSettings = false


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
                        // "Scan missing areas" jumps straight back into capture —
                        // no second "Start Scan" tap. The session has stayed live
                        // through coverage review, so `resumeSession()` (driven by
                        // `isResumingFromCoverage` in ScanningView.onAppear) keeps
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
                        handleStartScan()
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
                RoomLabelView(
                    roomLabel: $viewModel.roomLabel,
                    roomScope: $viewModel.roomScope,
                    rfqId: viewModel.selectedRFQ?.id
                ) {
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
                viewModel.saveToHistory(scanId: result.scanId, status: "uploaded")
                print("[RoomScanAlpha] Upload complete — scan ID: \(result.scanId)")

                // Processing now happens entirely server-side; the 360 room
                // view surfaces "Processing" as a scan status until the mesh
                // is ready. No need to poll here.
                viewModel.scanResult = CloudUploader.ScanResult(
                    scanId: result.scanId,
                    status: "uploaded",
                    floorAreaSqft: nil, wallAreaSqft: nil,
                    ceilingHeightFt: nil, perimeterLinearFt: nil,
                    detectedComponents: nil, scanDimensions: nil,
                    roomPolygonFt: nil, wallHeightsFt: nil,
                    polygonSource: nil, scanMeshUrl: nil,
                    fastCoverage: nil, inlineCoverage: nil
                )
                viewModel.state = .viewingResults
            } catch {
                viewModel.uploadError = error.localizedDescription
                viewModel.uploadStatus = "Upload failed"
                print("[RoomScanAlpha] Upload error: \(error)")
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

    @ViewBuilder
    private var idleView: some View {
        if workspaceMode, let org = account?.org {
            contractorIdleView(org: org)
        } else {
            personalIdleView
        }
    }

    private var personalIdleView: some View {
        HomeView(
            account: account,
            onAccountLoaded: { account = $0 },
            onStartScan: { latest in
                if let latest = latest {
                    // Jump straight to the AR "Start Scan" view — no
                    // intermediate project-overview page. User can back out
                    // if this is the wrong project.
                    viewModel.selectedRFQ = latest
                    viewModel.prepareScan()
                } else {
                    // No project yet → open the create-project sheet.
                    showNewProjectSheet = true
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
            onEnterWorkspace: {
                workspaceMode = true
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
            InboxView(role: .homeowner) { showInbox = false }
        }
        .sheet(isPresented: $showAccount) {
            AccountView(
                onClose: { showAccount = false },
                onGoToWorkspace: account?.org != nil ? { workspaceMode = true } : nil
            )
        }
        .sheet(isPresented: $showNewProjectSheet) {
            NewProjectSheet { title, description, address in
                showNewProjectSheet = false
                Task { await createRFQAndScan(title: title, description: description, address: address) }
            }
        }
    }

    /// Create a new RFQ then jump straight into the scan flow. Used when
    /// the user taps Start scan from an empty Home — they want to scan,
    /// not land in a project picker.
    private func createRFQAndScan(title: String, description: String, address: String?) async {
        do {
            let rfq = try await RFQService.shared.createRFQ(
                title: title, description: description, address: address
            )
            viewModel.selectedRFQ = rfq
            viewModel.prepareScan()
        } catch {
            print("[RoomScanAlpha] Failed to create RFQ: \(error.localizedDescription)")
        }
    }

    private func contractorIdleView(org: Account.OrgMembership) -> some View {
        ContractorHomeView(
            org: org,
            onSwitchToPersonal: { workspaceMode = false },
            onOpenInbox: { showInbox = true },
            onOpenJobs: { showJobs = true },
            onOpenGallery: { showGallery = true },
            onOpenTeam: { showTeam = true },
            onOpenServices: { showServices = true },
            onOpenSettings: { showSettings = true },
            onSignOut: {
                try? AuthManager.shared.signOut()
                isAuthenticated = false
            }
        )
        .sheet(isPresented: $showInbox) {
            InboxView(role: .org) { showInbox = false }
        }
        .sheet(isPresented: $showJobs) {
            JobsView { showJobs = false }
        }
        .sheet(isPresented: $showGallery) {
            OrgGalleryView { showGallery = false }
        }
        .sheet(isPresented: $showTeam) {
            OrgTeamView { showTeam = false }
        }
        .sheet(isPresented: $showServices) {
            OrgServicesView { showServices = false }
        }
        .sheet(isPresented: $showSettings) {
            OrgSettingsView { showSettings = false }
        }
    }

}

#Preview {
    ContentView()
}
