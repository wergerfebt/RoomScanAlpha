import SwiftUI

struct ContentView: View {
    @State private var viewModel = ScanViewModel()
    @State private var sessionManager = ARSessionManager()

    private let hasLiDAR = DeviceCapability.supportsLiDAR
    private let hasARKit = DeviceCapability.supportsARKit

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                idleView
            case .selectingRFQ:
                RFQSelectionView(selectedRFQ: $viewModel.selectedRFQ)
                    .onChange(of: viewModel.selectedRFQ) { _, newValue in
                        if newValue != nil {
                            viewModel.prepareScan()
                        }
                    }
            case .scanReady, .scanning:
                ScanningView(
                    sessionManager: sessionManager,
                    viewModel: viewModel,
                    onStart: { handleStartScan() },
                    onStop: { handleStopScan() },
                    onRedo: { handleRedoScan() }
                )
            case .annotatingCorners:
                // Placeholder — annotation UI is implemented in Step 3.
                // For now, skip straight to labeling.
                annotatingPlaceholderView
            case .labelingRoom:
                RoomLabelView(roomLabel: $viewModel.roomLabel) {
                    if let frame = sessionManager.session.currentFrame {
                        viewModel.buildRFQContext(worldTransform: frame.camera.transform)
                    } else {
                        viewModel.buildRFQContext(worldTransform: .init(1))
                    }
                    if viewModel.hasEnoughStorage {
                        startExport()
                    } else {
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
                    onDone: { viewModel.returnToIdle() },
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
        viewModel.stopScan()

        // Kick off post-scan frame selection in the background.
        // Runs while the user annotates corners — no blocking.
        sessionManager.frameCaptureManager.selectBestFrames()
    }

    private func handleRedoScan() {
        sessionManager.resetSession()
        viewModel.redoScan()
    }

    // MARK: - Annotating Placeholder

    /// Temporary view until Step 3 (corner annotation) is implemented.
    /// Waits for frame selection to complete, then auto-advances to labeling.
    private var annotatingPlaceholderView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
            Text("Preparing...")
                .font(.headline)
            Spacer()
        }
        .onAppear {
            // Pause the AR session now that we're past annotation placeholder
            sessionManager.pauseSession()
            advanceAfterFrameSelection()
        }
    }

    /// Wait for post-scan frame selection to finish before advancing.
    /// If selection already completed (or no pruning needed), advances immediately.
    private func advanceAfterFrameSelection() {
        let fcm = sessionManager.frameCaptureManager
        if fcm.selectionComplete || !fcm.isSelecting {
            advanceToLabelingOrWarning()
        } else {
            // Poll briefly — selection typically takes < 2s for 80 frames
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                advanceAfterFrameSelection()
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

        Task.detached {
            do {
                let result = try ScanPackager.package(
                    keyframes: keyframes,
                    meshAnchors: meshAnchors,
                    scanDuration: duration,
                    rfqContext: rfqContext,
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
    private func startPolling(scanId: String, rfqId: String) {
        viewModel.state = .viewingResults

        Task {
            do {
                let result = try await CloudUploader.shared.pollForResult(scanId: scanId, rfqId: rfqId)
                viewModel.scanResult = result
                viewModel.saveToHistory(scanId: scanId, status: result.status)
                print("[RoomScanAlpha] Scan result: \(result.status)")
            } catch {
                viewModel.saveToHistory(scanId: scanId, status: "failed")
                // Create a placeholder "failed" result so the UI can display the error state
                viewModel.scanResult = CloudUploader.ScanResult(
                    scanId: scanId,
                    status: "failed",
                    floorAreaSqft: nil,
                    wallAreaSqft: nil,
                    ceilingHeightFt: nil,
                    perimeterLinearFt: nil,
                    detectedComponents: nil,
                    scanDimensions: nil
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
            }
            .padding(.horizontal, 24)

            if hasLiDAR {
                if let rfq = viewModel.selectedRFQ {
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.blue)
                        Text(rfq.description ?? "Untitled Project")
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
                        viewModel.prepareScan()
                    } else {
                        viewModel.state = .selectingRFQ
                    }
                } label: {
                    Label(
                        viewModel.hasRFQSelected ? "Start Scan" : "Select Project to Scan",
                        systemImage: viewModel.hasRFQSelected ? "viewfinder" : "doc.text.magnifyingglass"
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
