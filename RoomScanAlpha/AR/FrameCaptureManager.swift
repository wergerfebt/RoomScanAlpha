// Captures continuous video from the AR session at ~10fps, writing each frame directly to an
// HEVC video file on disk via VideoFrameWriter. No frame pixel data is held in memory.
// Cloud handles all keyframe selection — device just records everything.

import ARKit
import simd

final class FrameCaptureManager {

    let videoWriter = VideoFrameWriter(depthInterval: 1)

    private var lastCaptureTime: TimeInterval = 0

    /// Called when the frame cap is reached. The session manager should stop capture.
    var onCapReached: (() -> Void)?
    private var capNotified = false

    // Continuous capture at ~10fps: write every 0.1s (every ~6th ARKit frame at 60fps).
    // No rotation/translation thresholds — HEVC inter-frame compression handles redundancy.
    // Cloud selects the best frames from the continuous stream.
    private let minimumInterval: TimeInterval = 0.1

    // Cap at 6000 frames (~10 minutes at 10fps). HEVC keeps this well under 200MB on disk.
    private let maxFrames: Int = 6000

    var keyframeCount: Int { videoWriter.frameCount }
    var isAtCapacity: Bool { videoWriter.frameCount >= maxFrames }

    func reset() {
        videoWriter.cleanup()
        lastCaptureTime = 0
        capNotified = false
    }

    /// Evaluate an ARFrame and write it to the HEVC video if enough time has elapsed.
    /// Returns true if a frame was written.
    @discardableResult
    func processFrame(_ frame: ARFrame) -> Bool {
        guard videoWriter.frameCount < maxFrames else {
            if !capNotified {
                capNotified = true
                print("[RoomScanAlpha] Frame cap reached (\(maxFrames)) — stopping capture")
                DispatchQueue.main.async { [self] in
                    onCapReached?()
                }
            }
            return false
        }

        guard !videoWriter.hasFailed else { return false }

        let currentTime = frame.timestamp

        // First frame is always captured.
        guard lastCaptureTime > 0 else {
            lastCaptureTime = currentTime
            return captureFrame(from: frame)
        }

        // Continuous capture at ~10fps — just check time interval, no movement thresholds.
        guard (currentTime - lastCaptureTime) >= minimumInterval else { return false }

        return captureFrame(from: frame)
    }

    /// Finalize the HEVC video and sidecar files. Call when capture ends (user taps stop).
    func finalizeCapture() async -> CaptureResult? {
        return await videoWriter.finishWriting()
    }

    // MARK: - Private

    private func captureFrame(from frame: ARFrame) -> Bool {
        let success = videoWriter.appendFrame(
            pixelBuffer: frame.capturedImage,
            timestamp: frame.timestamp,
            transform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            depthMap: frame.sceneDepth?.depthMap
        )

        if success {
            lastCaptureTime = frame.timestamp

            if videoWriter.frameCount % 100 == 0 {
                print("[RoomScanAlpha] Frame \(videoWriter.frameCount) captured (HEVC, depth: \(videoWriter.depthFrameCount))")
            }
        }

        return success
    }
}
