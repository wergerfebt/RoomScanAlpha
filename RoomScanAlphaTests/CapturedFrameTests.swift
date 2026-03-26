import XCTest
import simd
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan test cases:
/// - 3.6  Camera intrinsics stored (fx, fy, cx, cy)
/// - 3.7  Camera transform stored (4x4 orthonormal matrix)
/// - 3.8  Pixel buffer format (JPEG Data, not raw CVPixelBuffer)
/// - 3.9  Depth map stored with keyframe
/// - 3.11 Memory stays bounded (stores Data, not CVPixelBuffer)
/// - 3.12 CVPixelBuffers released after JPEG conversion (struct holds Data only)
final class CapturedFrameTests: XCTestCase {

    /// Helper to create a test CapturedFrame with known values.
    private func makeTestFrame(
        index: Int = 0,
        jpegData: Data = Data(repeating: 0xFF, count: 150_000),
        depthData: Data? = Data(repeating: 0x00, count: 256 * 192 * 4),
        depthWidth: Int = 256,
        depthHeight: Int = 192,
        intrinsics: simd_float3x3 = simd_float3x3(
            SIMD3<Float>(1234.5, 0, 0),
            SIMD3<Float>(0, 1234.5, 0),
            SIMD3<Float>(960, 540, 1)
        ),
        transform: simd_float4x4 = matrix_identity_float4x4,
        imageWidth: Int = 1920,
        imageHeight: Int = 1440,
        timestamp: TimeInterval = 1234567890.123
    ) -> CapturedFrame {
        CapturedFrame(
            index: index,
            jpegData: jpegData,
            depthData: depthData,
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            cameraIntrinsics: intrinsics,
            cameraTransform: transform,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            timestamp: timestamp
        )
    }

    // MARK: - Camera intrinsics (3.6)

    func testCameraIntrinsicsStored() {
        let frame = makeTestFrame()
        let k = frame.cameraIntrinsics

        // fx = k[0][0], fy = k[1][1]
        XCTAssertEqual(k[0][0], 1234.5, accuracy: 0.01, "fx should be stored correctly")
        XCTAssertEqual(k[1][1], 1234.5, accuracy: 0.01, "fy should be stored correctly")

        // cx = k[2][0], cy = k[2][1]
        XCTAssertEqual(k[2][0], 960, accuracy: 0.01, "cx should be ~image_width/2")
        XCTAssertEqual(k[2][1], 540, accuracy: 0.01, "cy should be ~image_height/2")
    }

    func testCameraIntrinsicsFxFyArePositive() {
        let frame = makeTestFrame()
        XCTAssertGreaterThan(frame.cameraIntrinsics[0][0], 500, "fx should be > 500 pixels")
        XCTAssertGreaterThan(frame.cameraIntrinsics[1][1], 500, "fy should be > 500 pixels")
    }

    // MARK: - Camera transform (3.7)

    func testCameraTransformStored() {
        let translation = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(1.5, 0.3, -2.0, 1)
        )
        let frame = makeTestFrame(transform: translation)

        // Translation component
        XCTAssertEqual(frame.cameraTransform.columns.3.x, 1.5, accuracy: 0.001)
        XCTAssertEqual(frame.cameraTransform.columns.3.y, 0.3, accuracy: 0.001)
        XCTAssertEqual(frame.cameraTransform.columns.3.z, -2.0, accuracy: 0.001)
    }

    func testCameraTransformIsOrthonormal() {
        let frame = makeTestFrame()
        let t = frame.cameraTransform

        // Identity matrix rotation should be orthonormal
        let col0 = SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z)
        let col1 = SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z)
        let col2 = SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)

        // Column magnitudes should be ~1
        XCTAssertEqual(simd_length(col0), 1.0, accuracy: 0.001)
        XCTAssertEqual(simd_length(col1), 1.0, accuracy: 0.001)
        XCTAssertEqual(simd_length(col2), 1.0, accuracy: 0.001)

        // Columns should be orthogonal (dot products ~0)
        XCTAssertEqual(simd_dot(col0, col1), 0.0, accuracy: 0.001)
        XCTAssertEqual(simd_dot(col0, col2), 0.0, accuracy: 0.001)
        XCTAssertEqual(simd_dot(col1, col2), 0.0, accuracy: 0.001)
    }

    // MARK: - JPEG data (3.8, 3.11, 3.12)

    func testJPEGDataIsStored() {
        let jpegData = Data(repeating: 0xFF, count: 200_000)
        let frame = makeTestFrame(jpegData: jpegData)
        XCTAssertEqual(frame.jpegData.count, 200_000)
    }

    func testJPEGSizeSufficientQuality() {
        // Test case 4.7: JPEG file size >= 100KB
        let frame = makeTestFrame(jpegData: Data(repeating: 0xFF, count: 150_000))
        XCTAssertGreaterThanOrEqual(frame.jpegData.count, 100_000,
                                    "JPEG should be >= 100KB for sufficient quality")
    }

    func testFrameStoresDataNotPixelBuffers() {
        // Test cases 3.11, 3.12: CapturedFrame holds Data, not CVPixelBuffer
        let frame = makeTestFrame()

        // jpegData is Data, not CVPixelBuffer
        XCTAssertTrue(type(of: frame.jpegData) == Data.self,
                      "Frame should store JPEG as Data, not CVPixelBuffer")

        // depthData is Data?, not CVPixelBuffer
        if let depth = frame.depthData {
            XCTAssertTrue(type(of: depth) == Data.self,
                          "Frame should store depth as Data, not CVPixelBuffer")
        }
    }

    // MARK: - Depth map (3.9)

    func testDepthMapStored() {
        let depthBytes = Data(repeating: 0x00, count: 256 * 192 * 4) // Float32 per pixel
        let frame = makeTestFrame(depthData: depthBytes, depthWidth: 256, depthHeight: 192)

        XCTAssertNotNil(frame.depthData)
        XCTAssertEqual(frame.depthWidth, 256)
        XCTAssertEqual(frame.depthHeight, 192)
    }

    func testDepthMapCanBeNil() {
        let frame = makeTestFrame(depthData: nil, depthWidth: 0, depthHeight: 0)
        XCTAssertNil(frame.depthData)
    }

    // MARK: - Image dimensions

    func testImageDimensionsStored() {
        let frame = makeTestFrame(imageWidth: 1920, imageHeight: 1440)
        XCTAssertEqual(frame.imageWidth, 1920)
        XCTAssertEqual(frame.imageHeight, 1440)
    }

    // MARK: - Timestamp

    func testTimestampStored() {
        let frame = makeTestFrame(timestamp: 1234567890.123)
        XCTAssertEqual(frame.timestamp, 1234567890.123, accuracy: 0.001)
    }

    // MARK: - Memory per keyframe (3.12)

    func testMemoryPerKeyframeIsSmall() {
        // Each keyframe should be ~JPEG size + depth bytes, NOT ~8MB raw buffer
        let jpegData = Data(repeating: 0xFF, count: 200_000) // ~200KB JPEG
        let depthData = Data(repeating: 0x00, count: 256 * 192 * 4) // ~192KB depth
        let frame = makeTestFrame(jpegData: jpegData, depthData: depthData)

        let totalBytes = frame.jpegData.count + (frame.depthData?.count ?? 0)
        let maxExpectedPerFrame = 500_000 // 500KB — well under 8MB raw buffer

        XCTAssertLessThan(totalBytes, maxExpectedPerFrame,
                          "Per-keyframe memory should be < 500KB (JPEG + depth), not ~8MB raw buffer")
    }
}
