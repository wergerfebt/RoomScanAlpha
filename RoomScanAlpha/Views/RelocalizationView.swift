import SwiftUI
import ARKit

/// Overlay shown while ARKit relocalizes against a saved ARWorldMap.
/// Shows the live camera feed with a status message. Transitions to the
/// gap re-scan view once tracking reaches `.normal`.
struct RelocalizationView: View {
    let sessionManager: ARSessionManager
    let onRelocalized: () -> Void
    let onCancel: () -> Void

    @State private var trackingStatus: String = "Relocalizing..."
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?
    /// Minimum time before accepting relocalization, to let the session settle.
    @State private var canAcceptRelocalization = false

    var body: some View {
        ZStack {
            ARRelocalizationSceneView(sessionManager: sessionManager, onTrackingStateChanged: handleTrackingState)
                .ignoresSafeArea()

            VStack {
                // Status banner
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text(trackingStatus)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }

                    Text("Point your camera at features from the original scan")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))

                    if elapsedSeconds >= 15 {
                        Text("Try moving to where you started the original scan")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
                .background(.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, 60)

                Spacer()

                // Cancel button
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.2))
                        .clipShape(Capsule())
                }
                .padding(.bottom, 48)
            }
        }
        .onAppear {
            elapsedSeconds = 0
            canAcceptRelocalization = false
            // Wait 1.5s before accepting relocalization to let the session settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                canAcceptRelocalization = true
            }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                elapsedSeconds += 1
                if elapsedSeconds >= 30 {
                    trackingStatus = "Relocalization taking longer than expected..."
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func handleTrackingState(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal:
            guard canAcceptRelocalization else { return }
            timer?.invalidate()
            timer = nil
            print("[RoomScanAlpha] Relocalization succeeded after \(elapsedSeconds)s")
            onRelocalized()
        case .limited(let reason):
            switch reason {
            case .relocalizing:
                trackingStatus = "Relocalizing..."
            case .initializing:
                trackingStatus = "Initializing..."
            case .excessiveMotion:
                trackingStatus = "Move slower..."
            case .insufficientFeatures:
                trackingStatus = "Not enough features — look at textured surfaces"
            @unknown default:
                trackingStatus = "Limited tracking..."
            }
        case .notAvailable:
            trackingStatus = "Tracking not available"
        }
    }
}

// MARK: - AR Scene View for Relocalization

private struct ARRelocalizationSceneView: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let onTrackingStateChanged: (ARCamera.TrackingState) -> Void

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView()
        scnView.session = sessionManager.session
        scnView.delegate = context.coordinator
        scnView.automaticallyUpdatesLighting = true
        return scnView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onTrackingStateChanged: onTrackingStateChanged)
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let onTrackingStateChanged: (ARCamera.TrackingState) -> Void
        private var lastReportedState: ARCamera.TrackingState?

        init(onTrackingStateChanged: @escaping (ARCamera.TrackingState) -> Void) {
            self.onTrackingStateChanged = onTrackingStateChanged
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let frame = (renderer as? ARSCNView)?.session.currentFrame else { return }
            let state = frame.camera.trackingState
            // Only report changes to avoid spamming the callback
            if state != lastReportedState {
                lastReportedState = state
                DispatchQueue.main.async {
                    self.onTrackingStateChanged(state)
                }
            }
        }
    }
}
