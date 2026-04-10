import XCTest
import simd
@testable import RoomScanAlpha

/// Tests for ScanPackager with HEVC CaptureResult input.
/// Verifies the package directory structure, metadata.json schema, and file copying.
final class ScanPackagerTests: XCTestCase {

    /// Create a mock CaptureResult with temp files simulating VideoFrameWriter output.
    private func makeMockCaptureResult(frameCount: Int = 100) throws -> CaptureResult {
        let tmp = FileManager.default.temporaryDirectory
        let id = UUID().uuidString.prefix(8)

        // Mock HEVC video file (just a data blob for testing)
        let videoURL = tmp.appendingPathComponent("test_video_\(id).mov")
        try Data(repeating: 0xAA, count: 8192).write(to: videoURL)

        // Mock pose sidecar (JSONL)
        let poseURL = tmp.appendingPathComponent("test_poses_\(id).jsonl")
        var poseData = Data()
        for i in 0..<frameCount {
            let line = "{\"i\":\(i),\"t\":\(1000.0 + Double(i) * 0.3),\"tx\":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],\"fx\":1234.5,\"fy\":1234.5,\"cx\":960,\"cy\":540,\"w\":1920,\"h\":1440,\"dw\":256,\"dh\":192,\"do\":\(i * 196608)}\n"
            poseData.append(line.data(using: .utf8)!)
        }
        try poseData.write(to: poseURL)

        // Mock depth sidecar (binary header + data)
        let depthURL = tmp.appendingPathComponent("test_depth_\(id).bin")
        var depthData = Data([0x44, 0x50, 0x54, 0x48]) // "DPTH" magic
        var version: UInt32 = 1
        depthData.append(Data(bytes: &version, count: 4))
        var count: UInt32 = UInt32(frameCount)
        depthData.append(Data(bytes: &count, count: 4))
        var bytesPerFrame: UInt32 = 256 * 192 * 4
        depthData.append(Data(bytes: &bytesPerFrame, count: 4))
        // Append minimal depth frames (small for test)
        for _ in 0..<min(frameCount, 3) {
            depthData.append(Data(repeating: 0x00, count: Int(bytesPerFrame)))
        }
        try depthData.write(to: depthURL)

        return CaptureResult(
            videoURL: videoURL,
            poseSidecarURL: poseURL,
            depthSidecarURL: depthURL,
            frameCount: frameCount,
            depthFrameCount: frameCount / 5,
            firstFrameIntrinsics: simd_float3x3(
                SIMD3<Float>(1234.5, 0, 0),
                SIMD3<Float>(0, 1234.5, 0),
                SIMD3<Float>(960, 540, 1)
            ),
            imageWidth: 1920,
            imageHeight: 1440,
            depthWidth: 256,
            depthHeight: 192
        )
    }

    private func packageTestScan(frameCount: Int = 100) throws -> ScanPackager.PackageResult {
        let captureResult = try makeMockCaptureResult(frameCount: frameCount)
        return try ScanPackager.package(
            captureResult: captureResult,
            meshAnchors: [],
            scanDuration: 45.2,
            rfqContext: nil,
            cornerAnnotation: nil,
            onProgress: { _ in }
        )
    }

    override func tearDown() {
        let tmpDir = FileManager.default.temporaryDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        ) {
            for url in contents where url.lastPathComponent.hasPrefix("scan_") || url.lastPathComponent.hasPrefix("test_") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        super.tearDown()
    }

    // MARK: - Directory structure

    func testPackageDirectoryStructure() throws {
        let result = try packageTestScan()
        let dir = result.directoryURL
        let fm = FileManager.default

        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("mesh.ply").path),
                      "mesh.ply should exist")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("metadata.json").path),
                      "metadata.json should exist")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("scan_video.mov").path),
                      "scan_video.mov should exist")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("poses.jsonl").path),
                      "poses.jsonl should exist")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("depth.bin").path),
                      "depth.bin should exist")
    }

    // MARK: - metadata.json

    func testMetadataContainsHEVCFormat() throws {
        let result = try packageTestScan()
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)

        XCTAssertEqual(metadata.captureFormat, "hevc")
        XCTAssertEqual(metadata.videoFilename, "scan_video.mov")
        XCTAssertEqual(metadata.poseSidecarFilename, "poses.jsonl")
        XCTAssertEqual(metadata.depthSidecarFilename, "depth.bin")
    }

    func testMetadataContainsAllRequiredKeys() throws {
        let result = try packageTestScan(frameCount: 50)
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)

        XCTAssertFalse(metadata.device.isEmpty, "metadata.json must contain 'device'")
        XCTAssertFalse(metadata.iosVersion.isEmpty, "metadata.json must contain 'ios_version'")
        XCTAssertEqual(metadata.frameCount, 50, "metadata.json must contain correct 'frame_count'")
        XCTAssertGreaterThanOrEqual(metadata.scanDurationSeconds, 0)
    }

    func testMetadataCameraIntrinsics() throws {
        let result = try packageTestScan()
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)

        XCTAssertEqual(metadata.cameraIntrinsics.fx, 1234.5, accuracy: 0.1)
        XCTAssertEqual(metadata.cameraIntrinsics.fy, 1234.5, accuracy: 0.1)
        XCTAssertGreaterThan(metadata.cameraIntrinsics.cx, 0)
        XCTAssertGreaterThan(metadata.cameraIntrinsics.cy, 0)
    }

    func testMetadataImageResolution() throws {
        let result = try packageTestScan()
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)

        XCTAssertEqual(metadata.imageResolution.width, 1920)
        XCTAssertEqual(metadata.imageResolution.height, 1440)
    }

    func testMetadataDepthFormat() throws {
        let result = try packageTestScan()
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)

        XCTAssertEqual(metadata.depthFormat.pixelFormat, "kCVPixelFormatType_DepthFloat32")
        XCTAssertEqual(metadata.depthFormat.width, 256)
        XCTAssertEqual(metadata.depthFormat.height, 192)
        XCTAssertEqual(metadata.depthFormat.byteOrder, "little_endian")
    }

    func testMetadataScanDuration() throws {
        let result = try packageTestScan()
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)

        XCTAssertEqual(metadata.scanDurationSeconds, 45.2, accuracy: 0.1)
    }

    func testMetadataMeshCounts() throws {
        let result = try packageTestScan()
        let data = try Data(contentsOf: result.directoryURL.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(ScanMetadata.self, from: data)

        XCTAssertEqual(metadata.meshVertexCount, 0)
        XCTAssertEqual(metadata.meshFaceCount, 0)
    }

    // MARK: - Package size

    func testPackageTotalSizePositive() throws {
        let result = try packageTestScan()
        XCTAssertGreaterThan(result.totalSizeBytes, 0)
    }

    // MARK: - Depth sidecar integrity

    func testDepthSidecarHasValidHeader() throws {
        let result = try packageTestScan()
        let depthURL = result.directoryURL.appendingPathComponent("depth.bin")
        let data = try Data(contentsOf: depthURL)

        XCTAssertGreaterThanOrEqual(data.count, 16, "Depth sidecar must have at least 16-byte header")
        // Check magic bytes "DPTH"
        XCTAssertEqual(data[0], 0x44)
        XCTAssertEqual(data[1], 0x50)
        XCTAssertEqual(data[2], 0x54)
        XCTAssertEqual(data[3], 0x48)
    }

    // MARK: - Pose sidecar integrity

    func testPoseSidecarHasCorrectLineCount() throws {
        let frameCount = 50
        let result = try packageTestScan(frameCount: frameCount)
        let poseURL = result.directoryURL.appendingPathComponent("poses.jsonl")
        let content = try String(contentsOf: poseURL, encoding: .utf8)
        let lines = content.split(separator: "\n")

        XCTAssertEqual(lines.count, frameCount, "Pose sidecar should have one line per frame")
    }
}
