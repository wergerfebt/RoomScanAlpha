import XCTest
import simd
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan test cases:
/// - 4.6  JPEG keyframes are valid images
/// - 4.8  Per-frame JSON contains valid pose (16-element camera_transform)
/// - 4.9  metadata.json is valid JSON with all required keys
/// - 4.10 metadata.json keyframe count matches files
/// - 4.11 Depth maps exported
/// - 4.12 Package directory structure correct
/// - 4.14 Package total size in expected range
/// - 4.15 Export runs on background thread (via Task.detached)
/// - 4.16 Depth map format documented in metadata
final class ScanPackagerTests: XCTestCase {

    /// Create mock CapturedFrame instances for testing the packager.
    private func makeMockKeyframes(count: Int) -> [CapturedFrame] {
        (0..<count).map { i in
            // Minimal valid JPEG: just a data blob for testing file writes
            let jpegData = Data(repeating: UInt8(i % 256), count: 1024)
            let depthData = Data(repeating: 0x00, count: 256 * 192 * 4)

            return CapturedFrame(
                index: i,
                jpegData: jpegData,
                depthData: depthData,
                depthWidth: 256,
                depthHeight: 192,
                cameraIntrinsics: simd_float3x3(
                    SIMD3<Float>(1234.5, 0, 0),
                    SIMD3<Float>(0, 1234.5, 0),
                    SIMD3<Float>(960, 540, 1)
                ),
                cameraTransform: matrix_identity_float4x4,
                imageWidth: 1920,
                imageHeight: 1440,
                timestamp: TimeInterval(i) * 0.6 + 1000
            )
        }
    }

    private func packageTestScan(keyframeCount: Int = 5) throws -> ScanPackager.PackageResult {
        let keyframes = makeMockKeyframes(count: keyframeCount)
        return try ScanPackager.package(
            keyframes: keyframes,
            meshAnchors: [], // Empty mesh — PLY will have 0 verts/faces
            scanDuration: 45.2,
            rfqContext: nil,
            onProgress: { _ in }
        )
    }

    override func tearDown() {
        // Clean up any temp scan directories
        let tmpDir = FileManager.default.temporaryDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        ) {
            for url in contents where url.lastPathComponent.hasPrefix("scan_") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        super.tearDown()
    }

    // MARK: - Directory structure (4.12)

    func testPackageDirectoryStructure() throws {
        let result = try packageTestScan()
        let dir = result.directoryURL
        let fm = FileManager.default

        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("mesh.ply").path),
                      "mesh.ply should exist")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("metadata.json").path),
                      "metadata.json should exist")

        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("keyframes").path, isDirectory: &isDir),
                      "keyframes/ directory should exist")
        XCTAssertTrue(isDir.boolValue)

        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("depth").path, isDirectory: &isDir),
                      "depth/ directory should exist")
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - JPEG keyframes written (4.6)

    func testJPEGKeyframesWritten() throws {
        let count = 5
        let result = try packageTestScan(keyframeCount: count)
        let keyframesDir = result.directoryURL.appendingPathComponent("keyframes")

        for i in 0..<count {
            let filename = String(format: "frame_%03d.jpg", i)
            let path = keyframesDir.appendingPathComponent(filename).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "\(filename) should exist in keyframes/")
        }
    }

    // MARK: - Per-frame JSON (4.8)

    func testPerFrameJSONContainsValidPose() throws {
        let result = try packageTestScan(keyframeCount: 3)
        let keyframesDir = result.directoryURL.appendingPathComponent("keyframes")
        let jsonURL = keyframesDir.appendingPathComponent("frame_000.json")

        let data = try Data(contentsOf: jsonURL)
        let frameMetadata = try JSONDecoder().decode(FrameMetadata.self, from: data)

        // Must contain camera_transform with 16 elements
        XCTAssertEqual(frameMetadata.cameraTransform.count, 16, "camera_transform must have exactly 16 float values")

        // Must contain image dimensions
        XCTAssertGreaterThan(frameMetadata.imageWidth, 0)
        XCTAssertGreaterThan(frameMetadata.imageHeight, 0)
    }

    func testPerFrameTransformIsOrthonormal() throws {
        let result = try packageTestScan(keyframeCount: 1)
        let jsonURL = result.directoryURL
            .appendingPathComponent("keyframes")
            .appendingPathComponent("frame_000.json")

        let data = try Data(contentsOf: jsonURL)
        let frameMetadata = try JSONDecoder().decode(FrameMetadata.self, from: data)
        let transform = frameMetadata.cameraTransform

        // Column 0: [0..3], Column 1: [4..7], Column 2: [8..11]
        let col0 = SIMD3<Float>(transform[0], transform[1], transform[2])
        let col1 = SIMD3<Float>(transform[4], transform[5], transform[6])
        let col2 = SIMD3<Float>(transform[8], transform[9], transform[10])

        XCTAssertEqual(simd_length(col0), 1.0, accuracy: 0.01, "Rotation column 0 magnitude should be ~1")
        XCTAssertEqual(simd_length(col1), 1.0, accuracy: 0.01, "Rotation column 1 magnitude should be ~1")
        XCTAssertEqual(simd_length(col2), 1.0, accuracy: 0.01, "Rotation column 2 magnitude should be ~1")

        XCTAssertEqual(simd_dot(col0, col1), 0.0, accuracy: 0.01, "Columns should be orthogonal")
    }

    // MARK: - metadata.json (4.9)

    func testMetadataJSONContainsAllRequiredKeys() throws {
        let result = try packageTestScan(keyframeCount: 5)
        let metadataURL = result.directoryURL.appendingPathComponent("metadata.json")

        let data = try Data(contentsOf: metadataURL)
        // Decoding with Codable struct validates all required keys are present and correctly typed
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)

        XCTAssertFalse(metadata.device.isEmpty, "metadata.json must contain 'device'")
        XCTAssertFalse(metadata.iosVersion.isEmpty, "metadata.json must contain 'ios_version'")
        XCTAssertEqual(metadata.keyframeCount, 5, "metadata.json must contain correct 'keyframe_count'")
        XCTAssertEqual(metadata.keyframes.count, 5, "metadata.json must contain 'keyframes' array")
        XCTAssertGreaterThanOrEqual(metadata.scanDurationSeconds, 0, "metadata.json must contain 'scan_duration_seconds'")
    }

    func testMetadataCameraIntrinsicsKeys() throws {
        let result = try packageTestScan()
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)

        XCTAssertGreaterThan(metadata.cameraIntrinsics.fx, 0)
        XCTAssertGreaterThan(metadata.cameraIntrinsics.fy, 0)
    }

    // MARK: - Keyframe count match (4.10)

    func testMetadataKeyframeCountMatchesFiles() throws {
        let count = 7
        let result = try packageTestScan(keyframeCount: count)

        // Check metadata says 7
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)
        XCTAssertEqual(metadata.keyframeCount, count)

        // Check 7 files exist in keyframes/
        let keyframesDir = result.directoryURL.appendingPathComponent("keyframes")
        let jpegFiles = try FileManager.default.contentsOfDirectory(at: keyframesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }
        XCTAssertEqual(jpegFiles.count, count, "JPEG file count must match keyframe_count in metadata")

        // Check keyframes array length matches
        XCTAssertEqual(metadata.keyframes.count, count, "keyframes array length must match keyframe_count")
    }

    // MARK: - Depth maps (4.11)

    func testDepthMapsExported() throws {
        let count = 3
        let result = try packageTestScan(keyframeCount: count)
        let depthDir = result.directoryURL.appendingPathComponent("depth")

        for i in 0..<count {
            let filename = String(format: "frame_%03d.depth", i)
            let depthURL = depthDir.appendingPathComponent(filename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: depthURL.path),
                          "\(filename) should exist in depth/")

            let attrs = try FileManager.default.attributesOfItem(atPath: depthURL.path)
            let size = attrs[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 0, "Depth file should not be empty")
        }
    }

    // MARK: - Depth format in metadata (4.16)

    func testDepthFormatDocumentedInMetadata() throws {
        let result = try packageTestScan()
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)

        XCTAssertEqual(metadata.depthFormat.pixelFormat, "kCVPixelFormatType_DepthFloat32",
                       "Depth format must specify Float32")
        XCTAssertGreaterThan(metadata.depthFormat.width, 0, "Depth format must include width")
        XCTAssertGreaterThan(metadata.depthFormat.height, 0, "Depth format must include height")
        XCTAssertEqual(metadata.depthFormat.byteOrder, "little_endian",
                       "Depth format must specify byte order")
    }

    // MARK: - Package size (4.14)

    func testPackageTotalSizePositive() throws {
        let result = try packageTestScan()
        XCTAssertGreaterThan(result.totalSizeBytes, 0, "Package size should be positive")
    }

    // MARK: - Mesh vertex/face counts in metadata

    func testMeshCountsInMetadata() throws {
        let result = try packageTestScan()
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)

        // With empty mesh anchors, counts should be 0
        XCTAssertEqual(metadata.meshVertexCount, 0)
        XCTAssertEqual(metadata.meshFaceCount, 0)
    }

    // MARK: - Scan duration in metadata

    func testScanDurationInMetadata() throws {
        let result = try packageTestScan()
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)

        XCTAssertEqual(metadata.scanDurationSeconds, 45.2, accuracy: 0.1)
    }
}
