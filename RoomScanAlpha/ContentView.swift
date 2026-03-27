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
                            viewModel.startScan()
                        }
                    }
            case .scanning:
                ScanningView(
                    sessionManager: sessionManager,
                    viewModel: viewModel,
                    onStop: { handleStopScan() }
                )
            case .labelingRoom:
                RoomLabelView(roomLabel: $viewModel.roomLabel) {
                    // Build RFQ context with AR world origin
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
                ExportingView(viewModel: viewModel, onDone: { viewModel.stopScan() })
            case .uploading:
                uploadingView
            case .viewingResults:
                ScanResultView(
                    viewModel: viewModel,
                    meshAnchors: sessionManager.lastMeshAnchors,
                    onDone: { viewModel.stopScan() },
                    onScanAnother: {
                        // Keep same RFQ, start a new scan for another room
                        viewModel.startScan()
                    }
                )
            }
        }
        .alert("Scan May Be Incomplete", isPresented: $viewModel.showQualityWarning) {
            Button("Export Anyway") { viewModel.state = .labelingRoom }
            Button("Continue Scanning") { viewModel.state = .scanning }
        } message: {
            Text("Only \(viewModel.keyframeCount) keyframes and \(viewModel.meshTriangleCount) triangles captured. For best results, capture at least 15 keyframes and 500 triangles.")
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

    private func handleStopScan() {
        sessionManager.pauseSession()

        if viewModel.scanQualitySufficient {
            viewModel.state = .labelingRoom
        } else {
            viewModel.showQualityWarning = true
        }
    }

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
                await MainActor.run {
                    viewModel.lastExportURL = result.directoryURL
                    let sizeMB = result.totalSizeBytes / 1024 / 1024
                    viewModel.exportProgress = "Export complete — \(sizeMB)MB"
                    print("[RoomScanAlpha] Export complete: \(result.directoryURL.path)")
                    // Check network before uploading
                    let network = CloudUploader.shared.checkNetwork()
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
                    viewModel.stopScan()
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
                        viewModel.startScan()
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
