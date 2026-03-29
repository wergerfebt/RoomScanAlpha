import ARKit

final class ARSessionManager: NSObject, ARSessionDelegate {
    let session = ARSession()
    let frameCaptureManager = FrameCaptureManager()

    var onMeshUpdate: (([ARMeshAnchor]) -> Void)?
    var onKeyframeCaptured: ((Int) -> Void)?

    /// Snapshot of mesh anchors at the time the session was paused, for export.
    private(set) var lastMeshAnchors: [ARMeshAnchor] = []
    private var isPaused = true

    /// When false, the AR session runs (for preview) but frames are not captured.
    var isCapturing = false

    override init() {
        super.init()
        session.delegate = self
    }

    func startSession() {
        frameCaptureManager.reset()
        lastMeshAnchors = []

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.frameSemantics.insert(.sceneDepth)
        config.environmentTexturing = .automatic
        isPaused = false
        session.run(config)
        print("[RoomScanAlpha] AR session started with LiDAR mesh reconstruction")
    }

    /// Snapshot mesh anchors without pausing the AR session.
    /// Used when transitioning to annotation — the session stays running so mesh reconstruction continues.
    func snapshotMeshAnchors() {
        if let frame = session.currentFrame {
            lastMeshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        }
        print("[RoomScanAlpha] Mesh snapshot — \(frameCaptureManager.keyframeCount) keyframes, \(lastMeshAnchors.count) mesh anchors")
    }

    func pauseSession() {
        // Guard against double-pause (ScanningView.onDisappear + ContentView.handleStopScan both call this).
        // The snapshot and log should only happen once.
        guard !isPaused else { return }
        isPaused = true

        if let frame = session.currentFrame {
            lastMeshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        }
        session.pause()
        print("[RoomScanAlpha] AR session paused — \(frameCaptureManager.keyframeCount) keyframes, \(lastMeshAnchors.count) mesh anchors")
    }

    /// Reset the AR session and clear all captured data. Used for redo.
    func resetSession() {
        frameCaptureManager.reset()
        lastMeshAnchors = []

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.frameSemantics.insert(.sceneDepth)
        config.environmentTexturing = .automatic
        isPaused = false
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        print("[RoomScanAlpha] AR session reset for redo")
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Only capture keyframes when actively scanning (not during preview or annotation)
        guard isCapturing else {
            // Still forward mesh updates for live preview
            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            if !meshAnchors.isEmpty {
                onMeshUpdate?(meshAnchors)
            }
            return
        }

        // Keyframe capture
        if frameCaptureManager.processFrame(frame) {
            onKeyframeCaptured?(frameCaptureManager.keyframeCount)
        }

        // Mesh updates
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        if !meshAnchors.isEmpty {
            onMeshUpdate?(meshAnchors)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        print("[RoomScanAlpha] AR session error: \(error.localizedDescription)")
    }

    var onSessionInterrupted: (() -> Void)?
    var onSessionResumed: (() -> Void)?

    func sessionWasInterrupted(_ session: ARSession) {
        print("[RoomScanAlpha] AR session interrupted")
        onSessionInterrupted?()
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        print("[RoomScanAlpha] AR session interruption ended")
        onSessionResumed?()
    }
}
