import SwiftUI
import ARKit

struct ScanningView: View {
    let sessionManager: ARSessionManager
    let viewModel: ScanViewModel
    let onStart: () -> Void
    let onStop: () -> Void
    let onRedo: () -> Void

    var body: some View {
        ZStack {
            ARScanningView(
                sessionManager: sessionManager,
                viewModel: viewModel,
                holes: viewModel.localHoles,
                uncoveredFaces: viewModel.localUncoveredFaces
            )
            .ignoresSafeArea()

            VStack {
                if viewModel.state == .scanning {
                    // Top HUD — only visible during active scanning
                    HStack(spacing: 12) {
                        statBadge(
                            icon: "triangle",
                            value: formatCount(viewModel.meshTriangleCount),
                            label: "triangles",
                            accessibilityValue: "\(viewModel.meshTriangleCount) triangles"
                        )
                        statBadge(
                            icon: "camera.fill",
                            value: "\(viewModel.keyframeCount)",
                            label: "frames",
                            accessibilityValue: "\(viewModel.keyframeCount) frames"
                        )
                        statBadge(
                            icon: "cube.transparent",
                            value: "\(viewModel.meshAnchorCount)",
                            label: "anchors",
                            accessibilityValue: "\(viewModel.meshAnchorCount) anchors"
                        )
                    }
                    .padding(.top, 8)
                }

                if viewModel.state == .scanReady || viewModel.state == .scanning {
                    ScanCoachOverlay(state: viewModel.coachingState)
                        .padding(.top, 8)
                        .animation(.easeOut(duration: 0.25), value: viewModel.coachingState)
                }

                Spacer()

                if viewModel.state == .scanReady {
                    // Pre-scan: "Start Scan" button centered
                    Button(action: onStart) {
                        Label("Start Scan", systemImage: "viewfinder")
                    }
                    .largeCapsuleButton(role: .primary, gradient: QTheme.forestGradient)
                    .accessibilityLabel("Start scanning")
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                } else if viewModel.state == .scanning {
                    // During scan: "Stop Scan" button
                    Button(action: onStop) {
                        Label("Stop Scan", systemImage: "stop.circle.fill")
                    }
                    .largeCapsuleButton(role: .secondary)
                    .accessibilityLabel("Stop scanning")
                    .padding(.bottom, 32)
                }
            }
            .dynamicTypeSize(.large ... .accessibility2)

            if !viewModel.isARSessionReady {
                bootOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: viewModel.isARSessionReady)
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
            sessionManager.onTrackingStateChange = { state in
                DispatchQueue.main.async {
                    // Only ever flip ready → true. Once ARKit has reached a
                    // normal tracking state we keep the HUD visible even if
                    // tracking briefly dips (limited / excessive motion), so
                    // the overlay doesn't flash back mid-scan.
                    if case .normal = state {
                        viewModel.isARSessionReady = true
                    }
                }
            }
            // Stop capture when frame cap is reached to avoid wasted CPU/memory
            sessionManager.frameCaptureManager.onCapReached = {
                sessionManager.isCapturing = false
                viewModel.showCapReachedAlert = true
            }
            // Start or resume AR session — capture is gated by isCapturing flag.
            // resumeSession() preserves frames + world coordinate system (for returning from coverage review).
            // startSession() resets everything (for a fresh new scan).
            if viewModel.isResumingFromCoverage {
                // Returning from coverage review — the session stayed running through
                // the review, so tracking is already normal. ARKit will NOT re-emit a
                // tracking-state change here, so we must mark ready synchronously.
                viewModel.isResumingFromCoverage = false
                viewModel.isARSessionReady = true
                sessionManager.resumeSession()
            } else {
                // Fresh scan (first scan or new room) — start clean and wait for ARKit
                // to report a normal tracking state before hiding the bootup overlay.
                viewModel.isARSessionReady = false
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

    /// Shown until ARKit reports a `.normal` tracking state. Masks the black
    /// startup frame so users don't think the app has crashed.
    private var bootOverlay: some View {
        ZStack {
            QTheme.forestInkGradient
                .ignoresSafeArea()
            VStack(spacing: 18) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(.white)
                Text("Starting camera…")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text("Hold the phone steady while the LiDAR sensor initializes.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting camera")
    }

    private func statBadge(
        icon: String,
        value: String,
        label: String,
        accessibilityValue: String
    ) -> some View {
        // Icon + number only — the icon carries the meaning, which keeps the
        // capsule narrow enough that the number never wraps on compact devices.
        // Full name stays in the VoiceOver label.
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.semibold)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityValue)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}
