import ARKit

final class ARSessionManager: NSObject, ARSessionDelegate {
    let session = ARSession()
    let frameCaptureManager = FrameCaptureManager()

    var onMeshUpdate: (([ARMeshAnchor]) -> Void)?
    var onKeyframeCaptured: ((Int) -> Void)?

    /// Snapshot of mesh anchors at the time the session was paused, for export.
    private(set) var lastMeshAnchors: [ARMeshAnchor] = []
    private var isPaused = true

    /// Stored configuration for resuming without resetting the world origin.
    private var currentConfig: ARWorldTrackingConfiguration?

    /// When false, the AR session runs (for preview) but frames are not captured.
    var isCapturing = false

    // MARK: - Panoramic Sweep

    /// When true, captures panoramic frames using tighter rotation thresholds.
    var isPanoramicCapture = false
    /// Frames captured during the 360° panoramic sweep.
    private(set) var panoramicFrames: [CapturedFrame] = []
    /// Camera transform when the panoramic sweep started (user facing corner 0).
    var panoramaStartTransform: simd_float4x4?
    /// Callback for panoramic frame count updates.
    var onPanoramicFrameCaptured: ((Int, Float) -> Void)?  // (count, yawDegrees)

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
        currentConfig = config
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

    /// Resume the AR session without resetting captured frames or world origin.
    /// Reuses the stored configuration to preserve the coordinate system.
    func resumeSession() {
        guard let config = currentConfig else {
            print("[RoomScanAlpha] Warning: no stored config, starting fresh session")
            startSession()
            return
        }
        isPaused = false
        session.run(config)
        print("[RoomScanAlpha] AR session resumed — \(frameCaptureManager.keyframeCount) keyframes preserved")
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

    func startPanoramicCapture() {
        panoramicFrames = []
        panoramaStartTransform = session.currentFrame?.camera.transform
        isPanoramicCapture = true
        print("[RoomScanAlpha] Panoramic capture started")
    }

    func stopPanoramicCapture() {
        isPanoramicCapture = false
        print("[RoomScanAlpha] Panoramic capture stopped — \(panoramicFrames.count) frames")
    }

    func resetPanoramicCapture() {
        panoramicFrames = []
        panoramaStartTransform = nil
        isPanoramicCapture = false
    }

    // MARK: - World Map Persistence

    /// Capture the current ARWorldMap and save it to disk.
    /// Must be called while the session is still running (before or immediately after pause).
    func saveWorldMap(to url: URL) async throws {
        let worldMap: ARWorldMap = try await withCheckedThrowingContinuation { continuation in
            session.getCurrentWorldMap { map, error in
                if let map = map {
                    continuation.resume(returning: map)
                } else {
                    continuation.resume(throwing: error ?? NSError(
                        domain: "ARSessionManager", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to get world map"]
                    ))
                }
            }
        }
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: worldMap, requiringSecureCoding: true
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        print("[RoomScanAlpha] World map saved: \(data.count / 1024)KB → \(url.lastPathComponent)")
    }

    /// Load a saved ARWorldMap and start a relocalized session.
    func startRelocalized(worldMapURL: URL) throws {
        let data = try Data(contentsOf: worldMapURL)
        guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: ARWorldMap.self, from: data
        ) else {
            throw NSError(domain: "ARSessionManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to decode ARWorldMap"])
        }

        frameCaptureManager.reset()
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.frameSemantics.insert(.sceneDepth)
        config.initialWorldMap = worldMap
        currentConfig = config
        isPaused = false
        session.run(config)
        print("[RoomScanAlpha] AR session started with saved world map for relocalization")
    }

    /// URL for storing an ARWorldMap for a given RFQ.
    static func worldMapURL(rfqId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("worldmaps/\(rfqId).worldmap")
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Panoramic capture mode (legacy — not used in HEVC path)
        if isPanoramicCapture {
            return
        }

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
