import SwiftUI
import ARKit

/// Guides the user through a 360° panoramic sweep for texture capture.
/// The user stands at the room center, faces the first annotation corner, then slowly rotates.
struct PanoramaSweepView: View {
    let sessionManager: ARSessionManager
    let viewModel: ScanViewModel
    let firstCorner: SIMD3<Float>?  // World position of first annotation corner (for alignment)
    let onDone: () -> Void
    let onSkip: () -> Void

    @State private var sweepStarted = false
    @State private var currentYaw: Float = 0
    @State private var maxYaw: Float = 0
    @State private var frameCount: Int = 0

    var body: some View {
        ZStack {
            // AR camera feed
            ARScanningView(sessionManager: sessionManager, viewModel: viewModel)
                .ignoresSafeArea()

            VStack {
                // Top prompt
                promptBanner
                    .padding(.top, 8)

                Spacer()

                // Rotation progress ring
                if sweepStarted {
                    progressRing
                        .padding(.bottom, 20)
                }

                // Controls
                controlBar
                    .padding(.bottom, 32)
            }
        }
        .onAppear {
            sessionManager.frameCaptureManager.resetPanoramicState()
            sessionManager.onPanoramicFrameCaptured = { count, yaw in
                frameCount = count
                currentYaw = yaw
                maxYaw = max(maxYaw, yaw)
                viewModel.panoramaFrameCount = count
            }
        }
        .onDisappear {
            if sessionManager.isPanoramicCapture {
                sessionManager.stopPanoramicCapture()
            }
        }
    }

    // MARK: - Prompt

    private var promptBanner: some View {
        Group {
            if !sweepStarted {
                VStack(spacing: 4) {
                    Text("Stand at the room center")
                        .fontWeight(.semibold)
                    Text("Face the first corner you marked, then tap Start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if maxYaw >= 330 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Sweep complete — \(frameCount) frames captured")
                }
            } else {
                Text("Slowly rotate in place... \(Int(maxYaw))° of 360°")
            }
        }
        .font(.subheadline)
        .fontWeight(.medium)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    // MARK: - Progress Ring

    private var progressRing: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 6)
                .frame(width: 80, height: 80)

            // Progress arc
            Circle()
                .trim(from: 0, to: CGFloat(min(maxYaw / 360.0, 1.0)))
                .stroke(maxYaw >= 330 ? Color.green : Color.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 80, height: 80)

            // Center text
            Text("\(Int(maxYaw))°")
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.bold)
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 20) {
            if !sweepStarted {
                Button("Skip") { onSkip() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    startSweep()
                } label: {
                    Label("Start Sweep", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
            } else {
                if maxYaw >= 330 {
                    Button {
                        finishSweep()
                    } label: {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                } else {
                    Text("\(frameCount) frames")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func startSweep() {
        viewModel.panoramaStartTransform = sessionManager.session.currentFrame?.camera.transform
        sessionManager.startPanoramicCapture()
        sweepStarted = true
    }

    private func finishSweep() {
        sessionManager.stopPanoramicCapture()
        onDone()
    }
}
