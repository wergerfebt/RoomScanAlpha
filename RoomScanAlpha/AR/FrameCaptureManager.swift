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
    // 60 cap: keeps total package under ~100MB (60 JPEGs + PLY + depth maps).
    private let maxKeyframes: Int = 60

    var keyframeCount: Int { capturedFrames.count }

    func reset() {
        capturedFrames.removeAll()
        lastCaptureTransform = nil
        lastCaptureTime = 0
        nextIndex = 0
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

    /// Angle in radians between two quaternions.
    private func angleBetween(_ q1: simd_quatf, _ q2: simd_quatf) -> Float {
        let dotProduct = abs(simd_dot(q1, q2))
        let clamped = min(dotProduct, 1.0)
        return 2.0 * acos(clamped)
    }
}
