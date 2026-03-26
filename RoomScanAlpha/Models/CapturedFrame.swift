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
        jpegQuality: CGFloat = 0.8
    ) -> CapturedFrame? {
        // Convert camera image (YCbCr CVPixelBuffer) → JPEG Data
        guard let jpegData = jpegFromPixelBuffer(frame.capturedImage, quality: jpegQuality) else {
            print("[RoomScanAlpha] Failed to convert frame \(index) to JPEG")
            return nil
        }

        let imageWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let imageHeight = CVPixelBufferGetHeight(frame.capturedImage)

        // Copy depth map to raw Data (Float32 bytes)
        var depthBytes: Data? = nil
        var dw = 0
        var dh = 0
        if let depthMap = frame.sceneDepth?.depthMap {
            depthBytes = copyDepthBuffer(depthMap)
            dw = CVPixelBufferGetWidth(depthMap)
            dh = CVPixelBufferGetHeight(depthMap)
        }

        return CapturedFrame(
            index: index,
            jpegData: jpegData,
            depthData: depthBytes,
            depthWidth: dw,
            depthHeight: dh,
            cameraIntrinsics: frame.camera.intrinsics,
            cameraTransform: frame.camera.transform,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            timestamp: frame.timestamp
        )
    }

    // MARK: - Private helpers

    private static func jpegFromPixelBuffer(_ pixelBuffer: CVPixelBuffer, quality: CGFloat) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: quality)
    }

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
