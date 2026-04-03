import SwiftUI

struct ScanningView: View {
    let sessionManager: ARSessionManager
    let viewModel: ScanViewModel
    let onStart: () -> Void
    let onStop: () -> Void
    let onRedo: () -> Void

    var body: some View {
        ZStack {
            ARScanningView(sessionManager: sessionManager, viewModel: viewModel)
                .ignoresSafeArea()

            VStack {
                if viewModel.state == .scanning {
                    // Top HUD — only visible during active scanning
                    HStack(spacing: 12) {
                        statBadge(
                            icon: "triangle",
                            value: formatCount(viewModel.meshTriangleCount),
                            label: "triangles"
                        )
                        statBadge(
                            icon: "camera.fill",
                            value: "\(viewModel.keyframeCount)",
                            label: "frames"
                        )
                        statBadge(
                            icon: "cube.transparent",
                            value: "\(viewModel.meshAnchorCount)",
                            label: "anchors"
                        )
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(viewModel.meshTriangleCount) triangles, \(viewModel.keyframeCount) frames, \(viewModel.meshAnchorCount) anchors")
                    .padding(.top, 8)
                }

                Spacer()

                if viewModel.state == .scanReady {
                    // Pre-scan: "Start Scan" button centered
                    Button(action: onStart) {
                        Label("Start Scan", systemImage: "viewfinder")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 16)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .accessibilityLabel("Start scanning")
                    .padding(.bottom, 32)
                } else if viewModel.state == .scanning {
                    // During scan: "Stop Scan" button
                    Button(action: onStop) {
                        Label("Stop Scan", systemImage: "stop.circle.fill")
                            .font(.headline)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .accessibilityLabel("Stop scanning")
                    .padding(.bottom, 32)
                }
            }
        }
        .onAppear {
            sessionManager.onKeyframeCaptured = { count in
                DispatchQueue.main.async {
                    viewModel.updateKeyframeCount(count)
                }
            }
            sessionManager.onSessionInterrupted = {
                DispatchQueue.main.async {
                    viewModel.showInterruptionAlert = true
                }
            }
            // Stop capture when frame cap is reached to avoid wasted CPU/memory
            sessionManager.frameCaptureManager.onCapReached = {
                sessionManager.isCapturing = false
                viewModel.showCapReachedAlert = true
            }
            // Start or resume AR session — capture is gated by isCapturing flag.
            // Use resumeSession() if frames already exist (returning from coverage review)
            // to avoid wiping captured frames.
            if sessionManager.frameCaptureManager.keyframeCount > 0 {
                sessionManager.resumeSession()
            } else {
                sessionManager.startSession()
            }
        }
        .onDisappear {
            sessionManager.isCapturing = false
            // Only pause if we're NOT transitioning to annotation (which needs a live session).
            // handleAnnotationDone/Skip will pause the session after annotation completes.
            if viewModel.state != .annotatingCorners
                && viewModel.state != .capturingPanorama
                && viewModel.state != .reviewingCoverage {
                sessionManager.pauseSession()
            }
        }
    }

    private func statBadge(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}
