import ARKit

final class ARSessionManager: NSObject, ARSessionDelegate {
    let session = ARSession()
    let frameCaptureManager = FrameCaptureManager()

    var onMeshUpdate: (([ARMeshAnchor]) -> Void)?
    var onKeyframeCaptured: ((Int) -> Void)?

    /// Snapshot of mesh anchors at the time the session was paused, for export.
    private(set) var lastMeshAnchors: [ARMeshAnchor] = []

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
        session.run(config)
        print("[RoomScanAlpha] AR session started with LiDAR mesh reconstruction")
    }

    func pauseSession() {
        // Snapshot mesh anchors before pausing
        if let frame = session.currentFrame {
            lastMeshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        }
        session.pause()
        print("[RoomScanAlpha] AR session paused — \(frameCaptureManager.keyframeCount) keyframes, \(lastMeshAnchors.count) mesh anchors")
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
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

    func sessionWasInterrupted(_ session: ARSession) {
        print("[RoomScanAlpha] AR session interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        print("[RoomScanAlpha] AR session interruption ended")
    }
}
