// Selects keyframes from the AR session based on camera movement thresholds, converting each to
// JPEG immediately to avoid retaining large CVPixelBuffers in memory.

import ARKit
import simd

final class FrameCaptureManager {
    private(set) var capturedFrames: [CapturedFrame] = []

    private var lastCaptureTransform: simd_float4x4?
    private var lastCaptureTime: TimeInterval = 0
    private var nextIndex: Int = 0
    private var capNotified: Bool = false

    // Thresholds — denser capture (8°/0.3s) replaces the separate panoramic sweep phase.
    // 0.15m translation: captures a new angle every ~6 inches — enough overlap for ORB matching
    // without excessive redundancy.
    private let translationThreshold: Float = 0.15
    // 8 deg rotation: dense angular coverage for texture projection and OpenMVS.
    private let rotationThreshold: Float = 8.0
    // 0.3s minimum: denser temporal capture while avoiding burst from hand tremor.
    private let minimumInterval: TimeInterval = 0.3
    // 300 cap: capture up to 300 frames, then post-scan selection keeps best 180.
    // After selection (180 kept), there's room for 120 more on rescan.
    private let maxKeyframes: Int = 300

    /// Called when the frame cap is reached. The session manager should set isCapturing = false.
    var onCapReached: (() -> Void)?

    var keyframeCount: Int { capturedFrames.count }
    var isAtCapacity: Bool { capturedFrames.count >= maxKeyframes }

    func reset() {
        capturedFrames.removeAll()
        lastCaptureTransform = nil
        lastCaptureTime = 0
        nextIndex = 0
        isSelecting = false
        selectionComplete = false
        capNotified = false
    }

    /// Evaluate an ARFrame and capture a keyframe if selection criteria are met.
    /// Returns true if a keyframe was captured.
    @discardableResult
    func processFrame(_ frame: ARFrame) -> Bool {
        guard capturedFrames.count < maxKeyframes else {
            // Cap reached — notify once to stop capture pipeline
            if !capNotified {
                capNotified = true
                print("[RoomScanAlpha] Frame cap reached (\(maxKeyframes)) — stopping capture")
                DispatchQueue.main.async { [self] in
                    onCapReached?()
                }
            }
            return false
        }

        let currentTransform = frame.camera.transform
        let currentTime = frame.timestamp

        // First frame is always captured
        guard let lastTransform = lastCaptureTransform else {
            return captureKeyframe(from: frame)
        }

        // Minimum interval check
        guard (currentTime - lastCaptureTime) >= minimumInterval else { return false }

        // Translation check
        let lastPos = SIMD3<Float>(lastTransform.columns.3.x, lastTransform.columns.3.y, lastTransform.columns.3.z)
        let currentPos = SIMD3<Float>(currentTransform.columns.3.x, currentTransform.columns.3.y, currentTransform.columns.3.z)
        let translationDistance = simd_length(currentPos - lastPos)

        // Rotation check
        let lastRotation = simd_quatf(lastTransform)
        let currentRotation = simd_quatf(currentTransform)
        let rotationAngle = angleBetween(lastRotation, currentRotation)

        let movedEnough = translationDistance >= translationThreshold
        let rotatedEnough = rotationAngle >= (rotationThreshold * .pi / 180.0)

        guard movedEnough || rotatedEnough else { return false }

        return captureKeyframe(from: frame)
    }

    private func captureKeyframe(from frame: ARFrame) -> Bool {
        guard let captured = CapturedFrame.from(frame: frame, index: nextIndex) else {
            return false
        }

        capturedFrames.append(captured)
        lastCaptureTransform = frame.camera.transform
        lastCaptureTime = frame.timestamp
        nextIndex += 1

        let jpegSizeKB = captured.jpegData.count / 1024
        let depthSizeKB = (captured.depthData?.count ?? 0) / 1024
        print("[RoomScanAlpha] Keyframe \(captured.index) captured — JPEG: \(jpegSizeKB)KB, depth: \(depthSizeKB)KB, total frames: \(capturedFrames.count)")

        return true
    }

    // MARK: - Post-Scan Frame Selection

    /// Whether frame selection is currently running.
    private(set) var isSelecting = false

    /// Whether frame selection has completed.
    private(set) var selectionComplete = false

    /// Score all captured frames and keep the best `targetCount`.
    /// Runs on a background queue; calls `completion` on the main queue when done.
    func selectBestFrames(
        targetCount: Int = FrameQualityScorer.targetFrameCount,
        completion: (() -> Void)? = nil
    ) {
        guard capturedFrames.count > targetCount else {
            selectionComplete = true
            completion?()
            return
        }

        isSelecting = true

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Score each frame
            let scored = self.capturedFrames.map { frame -> (frame: CapturedFrame, score: Float) in
                let score = FrameQualityScorer.score(jpegData: frame.jpegData)
                return (frame, score)
            }

            // Sort descending by score, keep top N
            let sorted = scored.sorted { $0.score > $1.score }
            let kept = sorted.prefix(targetCount).map(\.frame)

            // Re-sort by original index to maintain temporal order
            let reordered = kept.sorted { $0.index < $1.index }

            let discardedCount = self.capturedFrames.count - targetCount
            print("[RoomScanAlpha] Frame selection: kept \(targetCount) of \(self.capturedFrames.count) — discarded \(discardedCount) lowest-scoring frames")

            DispatchQueue.main.async {
                self.capturedFrames = reordered
                self.isSelecting = false
                self.selectionComplete = true
                // Reset cap flag — after selection (300→180), there's room for 120 more on rescan
                self.capNotified = false
                completion?()
            }
        }
    }

    // MARK: - Panoramic Sweep Capture

    struct PanoramicCaptureResult {
        let frame: CapturedFrame
        let yawDegrees: Float
    }

    private var lastPanoramicTransform: simd_float4x4?
    private var lastPanoramicTime: TimeInterval = 0
    private var panoramicIndex: Int = 0

    /// Rotation-only threshold for panoramic sweep (5° vs 15° for walk-around).
    private let panoramicRotationThreshold: Float = 5.0
    private let panoramicMinInterval: TimeInterval = 0.15
    private let maxPanoramicFrames: Int = 120

    /// Process a frame during panoramic sweep capture.
    /// Uses rotation-only threshold (5°), no translation threshold.
    /// Returns the captured frame + current yaw relative to start, or nil if not captured.
    func processPanoramicFrame(_ frame: ARFrame, startTransform: simd_float4x4?) -> PanoramicCaptureResult? {
        guard panoramicIndex < maxPanoramicFrames else { return nil }

        let currentTransform = frame.camera.transform
        let currentTime = frame.timestamp

        // First frame always captured
        guard let lastTransform = lastPanoramicTransform else {
            lastPanoramicTransform = currentTransform
            lastPanoramicTime = currentTime
            return capturePanoramicFrame(from: frame, startTransform: startTransform)
        }

        guard (currentTime - lastPanoramicTime) >= panoramicMinInterval else { return nil }

        // Rotation-only check (ignore translation — user should be stationary)
        let lastRot = simd_quatf(lastTransform)
        let currentRot = simd_quatf(currentTransform)
        let angle = angleBetween(lastRot, currentRot)

        guard angle >= (panoramicRotationThreshold * .pi / 180.0) else { return nil }

        lastPanoramicTransform = currentTransform
        lastPanoramicTime = currentTime
        return capturePanoramicFrame(from: frame, startTransform: startTransform)
    }

    private func capturePanoramicFrame(from frame: ARFrame, startTransform: simd_float4x4?) -> PanoramicCaptureResult? {
        guard let captured = CapturedFrame.from(frame: frame, index: panoramicIndex) else {
            return nil
        }

        panoramicIndex += 1

        // Compute yaw relative to start heading
        var yaw: Float = 0
        if let start = startTransform {
            let startForward = -SIMD3<Float>(start.columns.2.x, start.columns.2.y, start.columns.2.z)
            let currentForward = -SIMD3<Float>(frame.camera.transform.columns.2.x, frame.camera.transform.columns.2.y, frame.camera.transform.columns.2.z)
            let startYaw = atan2(startForward.x, startForward.z)
            let currentYaw = atan2(currentForward.x, currentForward.z)
            yaw = (currentYaw - startYaw) * 180.0 / .pi
            if yaw < 0 { yaw += 360 }
        }

        print("[RoomScanAlpha] Panoramic frame \(captured.index) — yaw: \(String(format: "%.0f", yaw))°")
        return PanoramicCaptureResult(frame: captured, yawDegrees: yaw)
    }

    func resetPanoramicState() {
        lastPanoramicTransform = nil
        lastPanoramicTime = 0
        panoramicIndex = 0
    }

    /// Angle in radians between two quaternions.
    private func angleBetween(_ q1: simd_quatf, _ q2: simd_quatf) -> Float {
        let dotProduct = abs(simd_dot(q1, q2))
        let clamped = min(dotProduct, 1.0)
        return 2.0 * acos(clamped)
    }
}
