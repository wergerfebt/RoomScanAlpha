// Selects keyframes from the AR session based on camera movement thresholds, converting each to
// JPEG immediately to avoid retaining large CVPixelBuffers in memory.

import ARKit
import simd

final class FrameCaptureManager {
    private(set) var capturedFrames: [CapturedFrame] = []

    private var lastCaptureTransform: simd_float4x4?
    private var lastCaptureTime: TimeInterval = 0
    private var nextIndex: Int = 0

    // Thresholds — tuned for 30-60 keyframes when walking the perimeter of a ~4x4m room.
    // 0.15m translation: captures a new angle every ~6 inches — enough overlap for ORB matching
    // without excessive redundancy.
    private let translationThreshold: Float = 0.15
    // 15 deg rotation: captures new viewpoints when turning corners or looking up/down.
    private let rotationThreshold: Float = 15.0
    // 0.5s minimum: prevents burst captures from hand tremor or rapid panning.
    private let minimumInterval: TimeInterval = 0.5
    // 80 cap: capture ~80 frames during scan, then post-scan selection keeps best 60.
    private let maxKeyframes: Int = 80

    var keyframeCount: Int { capturedFrames.count }

    func reset() {
        capturedFrames.removeAll()
        lastCaptureTransform = nil
        lastCaptureTime = 0
        nextIndex = 0
        isSelecting = false
        selectionComplete = false
    }

    /// Evaluate an ARFrame and capture a keyframe if selection criteria are met.
    /// Returns true if a keyframe was captured.
    @discardableResult
    func processFrame(_ frame: ARFrame) -> Bool {
        guard capturedFrames.count < maxKeyframes else { return false }

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
                completion?()
            }
        }
    }

    /// Angle in radians between two quaternions.
    private func angleBetween(_ q1: simd_quatf, _ q2: simd_quatf) -> Float {
        let dotProduct = abs(simd_dot(q1, q2))
        let clamped = min(dotProduct, 1.0)
        return 2.0 * acos(clamped)
    }
}
