// Stores a single keyframe's data (JPEG image, depth map, camera pose) captured during a room scan.
// All pixel buffers are converted to Data immediately on capture to prevent memory pressure.

import ARKit
import UIKit

struct CapturedFrame {
    let index: Int
    let jpegData: Data
    let depthData: Data?
    let depthWidth: Int
    let depthHeight: Int
    let cameraIntrinsics: simd_float3x3
    let cameraTransform: simd_float4x4
    let imageWidth: Int
    let imageHeight: Int
    let timestamp: TimeInterval

    /// Create a CapturedFrame from an ARFrame.
    /// Converts the camera image to JPEG and copies depth map bytes immediately
    /// so that the original CVPixelBuffers can be released.
    static func from(
        frame: ARFrame,
        index: Int,
        jpegQuality: CGFloat = 0.7 // 0.7 saves ~30% memory vs 0.8 with negligible texture quality loss
    ) -> CapturedFrame? {
        // Convert camera image (YCbCr CVPixelBuffer) → JPEG Data
        guard let jpegData = jpegFromPixelBuffer(frame.capturedImage, quality: jpegQuality) else {
            print("[RoomScanAlpha] Failed to convert frame \(index) to JPEG")
            return nil
        }

        let imageWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let imageHeight = CVPixelBufferGetHeight(frame.capturedImage)

        // Copy depth map pixels to a contiguous Data blob (Float32, little-endian, row-major).
        // The raw bytes are written directly to the .depth export file — the cloud processor
        // reads them back using the width/height/format from metadata.json.
        var depthBytes: Data? = nil
        var depthWidth = 0
        var depthHeight = 0
        if let depthMap = frame.sceneDepth?.depthMap {
            depthBytes = copyDepthBuffer(depthMap)
            depthWidth = CVPixelBufferGetWidth(depthMap)
            depthHeight = CVPixelBufferGetHeight(depthMap)
        }

        return CapturedFrame(
            index: index,
            jpegData: jpegData,
            depthData: depthBytes,
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            cameraIntrinsics: frame.camera.intrinsics,
            cameraTransform: frame.camera.transform,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            timestamp: frame.timestamp
        )
    }

    // MARK: - Private helpers

    // Shared CIContext — allocated once, reused for all keyframe JPEG conversions.
    // CIContext() allocates GPU resources, so creating one per frame wastes ~1-2ms each time.
    private static let sharedCIContext = CIContext()

    /// Convert an ARKit camera image (YCbCr biplanar CVPixelBuffer) to JPEG Data.
    /// Uses CIContext for the colorspace conversion, then UIImage for JPEG compression.
    private static func jpegFromPixelBuffer(_ pixelBuffer: CVPixelBuffer, quality: CGFloat) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = sharedCIContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: quality)
    }

    /// Copy a depth map CVPixelBuffer's pixels into a contiguous Data blob.
    /// The buffer must be locked for reading before accessing the base address;
    /// the defer block ensures it is always unlocked, even on early return.
    /// Output is raw Float32 bytes in row-major order, little-endian (native ARM).
    private static func copyDepthBuffer(_ pixelBuffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let totalBytes = bytesPerRow * height

        return Data(bytes: baseAddress, count: totalBytes)
    }
}
