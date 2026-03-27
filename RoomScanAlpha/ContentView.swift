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
            case .scanning:
                ScanningView(
                    sessionManager: sessionManager,
                    viewModel: viewModel,
                    onStop: { handleStopScan() }
                )
            case .exporting:
                ExportingView(viewModel: viewModel, onDone: { viewModel.stopScan() })
            }
        }
        .alert("Scan May Be Incomplete", isPresented: $viewModel.showQualityWarning) {
            Button("Export Anyway") { startExport() }
            Button("Continue Scanning") { viewModel.state = .scanning }
        } message: {
            Text("Only \(viewModel.keyframeCount) keyframes and \(viewModel.meshTriangleCount) triangles captured. For best results, capture at least 15 keyframes and 500 triangles.")
        }
    }

    private func handleStopScan() {
        sessionManager.pauseSession()

        if viewModel.scanQualitySufficient {
            startExport()
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

        Task.detached {
            do {
                let result = try ScanPackager.package(
                    keyframes: keyframes,
                    meshAnchors: meshAnchors,
                    scanDuration: duration,
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

    // MARK: - Idle View

    private var idleView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: hasLiDAR ? "camera.viewfinder" : "exclamationmark.triangle")
                .font(.system(size: 64))
                .foregroundStyle(hasLiDAR ? .blue : .orange)

            Text("RoomScan Alpha")
                .font(.largeTitle)
                .fontWeight(.bold)

            if hasLiDAR {
                capabilityRow(label: "ARKit", supported: true)
                capabilityRow(label: "LiDAR Scanner", supported: true)
                capabilityRow(label: "Scene Depth", supported: DeviceCapability.supportsSceneDepth)

                Button {
                    viewModel.startScan()
                } label: {
                    Label("Start Scan", systemImage: "viewfinder")
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
