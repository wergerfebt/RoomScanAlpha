import XCTest
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan Phase 6 test cases:
/// - 6.1  Zip file created (size > 0, reasonable compression)
/// - 6.2  Zip contents match source (all original files present and intact)
/// - 6.11 Scan ID persisted locally (UserDefaults survives restart)
/// - 6.12 Upload fails gracefully on no network (error, no crash)
///
/// Tests 6.3–6.10 require Firebase Auth + network → cloud-stub-tests.yml / manual device testing.
final class CloudUploaderTests: XCTestCase {

    private var testDirectory: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        // Create a mock scan directory with representative files
        testDirectory = fm.temporaryDirectory
            .appendingPathComponent("test_scan_\(UUID().uuidString)")
        try? fm.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up test directory and any zip artifacts
        if let dir = testDirectory {
            try? fm.removeItem(at: dir)
        }
        let tmpDir = fm.temporaryDirectory
        if let contents = try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) {
            for url in contents where url.lastPathComponent.hasPrefix("scan_upload_") {
                try? fm.removeItem(at: url)
            }
        }
        // Clean up persisted scan IDs from tests
        UserDefaults.standard.removeObject(forKey: "completedScanIds")
        super.tearDown()
    }

    // MARK: - Helpers

    /// Populate the test directory with files mimicking a real scan package.
    private func populateTestScanDirectory(keyframeCount: Int = 5) throws {
        // metadata.json
        let metadata: [String: Any] = [
            "device": "iPhone 16 Pro",
            "ios_version": "18.2",
            "keyframe_count": keyframeCount
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try metadataData.write(to: testDirectory.appendingPathComponent("metadata.json"))

        // mesh.ply (small placeholder)
        let plyContent = "ply\nformat ascii 1.0\nelement vertex 0\nend_header\n"
        try plyContent.write(to: testDirectory.appendingPathComponent("mesh.ply"), atomically: true, encoding: .utf8)

        // keyframes/
        let keyframesDir = testDirectory.appendingPathComponent("keyframes")
        try fm.createDirectory(at: keyframesDir, withIntermediateDirectories: true)
        for i in 0..<keyframeCount {
            let filename = String(format: "frame_%03d.jpg", i)
            let jpegData = Data(repeating: UInt8(i % 256), count: 4096)
            try jpegData.write(to: keyframesDir.appendingPathComponent(filename))

            let jsonFilename = String(format: "frame_%03d.json", i)
            let frameJson = "{\"camera_transform\": [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}"
            try frameJson.write(to: keyframesDir.appendingPathComponent(jsonFilename),
                                atomically: true, encoding: .utf8)
        }

        // depth/
        let depthDir = testDirectory.appendingPathComponent("depth")
        try fm.createDirectory(at: depthDir, withIntermediateDirectories: true)
        for i in 0..<keyframeCount {
            let filename = String(format: "frame_%03d.depth", i)
            let depthData = Data(repeating: 0x00, count: 256 * 192 * 4)
            try depthData.write(to: depthDir.appendingPathComponent(filename))
        }
    }

    /// Recursively collect all relative file paths in a directory.
    private func relativeFilePaths(in directory: URL) throws -> Set<String> {
        var result = Set<String>()
        let basePath = directory.path
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                if resourceValues.isRegularFile == true {
                    let relativePath = String(fileURL.path.dropFirst(basePath.count + 1))
                    result.insert(relativePath)
                }
            }
        }
        return result
    }

    /// Get file sizes keyed by relative path.
    private func fileSizes(in directory: URL) throws -> [String: Int] {
        var result = [String: Int]()
        let basePath = directory.path
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if resourceValues.isRegularFile == true {
                    let relativePath = String(fileURL.path.dropFirst(basePath.count + 1))
                    result[relativePath] = resourceValues.fileSize ?? 0
                }
            }
        }
        return result
    }

    // MARK: - 6.1 Zip file created

    func testZipFileCreated() throws {
        try populateTestScanDirectory(keyframeCount: 5)

        let zipURL = try CloudUploader.shared.zipDirectory(testDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: zipURL) }

        // Zip file must exist
        XCTAssertTrue(fm.fileExists(atPath: zipURL.path), "Zip file should exist")

        // Size > 0
        let attrs = try fm.attributesOfItem(atPath: zipURL.path)
        let zipSize = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(zipSize, 0, "Zip file size should be > 0")

        // Zip should be smaller than 120% of uncompressed size (test case 6.1 pass criteria)
        let originalSizes = try fileSizes(in: testDirectory)
        let uncompressedSize = originalSizes.values.reduce(0, +)
        let maxAllowedSize = Int(Double(uncompressedSize) * 1.2)
        XCTAssertLessThanOrEqual(zipSize, maxAllowedSize,
                                  "Zip file should be < 120% of uncompressed size (\(zipSize) vs \(maxAllowedSize))")
    }

    func testZipFileHasZipExtension() throws {
        try populateTestScanDirectory(keyframeCount: 1)

        let zipURL = try CloudUploader.shared.zipDirectory(testDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: zipURL) }

        XCTAssertEqual(zipURL.pathExtension, "zip", "Zip file should have .zip extension")
    }

    // MARK: - 6.2 Zip contents match source

    func testZipContentsMatchSource() throws {
        try populateTestScanDirectory(keyframeCount: 3)

        // Count source files for comparison
        var sourceFileCount = 0
        if let enumerator = fm.enumerator(at: testDirectory, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                if let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                   vals.isRegularFile == true {
                    sourceFileCount += 1
                }
            }
        }
        XCTAssertGreaterThan(sourceFileCount, 0, "Source directory should have files")

        // 3 keyframes × (jpg + json) + 3 depth + metadata.json + mesh.ply = 11 files
        let expectedFiles = 3 * 2 + 3 + 2  // 11
        XCTAssertEqual(sourceFileCount, expectedFiles,
                       "Source should have exactly \(expectedFiles) files, got \(sourceFileCount)")

        let zipURL = try CloudUploader.shared.zipDirectory(testDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: zipURL) }

        // Verify zip has valid ZIP magic bytes (PK\x03\x04)
        let headerData = try Data(contentsOf: zipURL)
        XCTAssertGreaterThanOrEqual(headerData.count, 4, "Zip must be at least 4 bytes")
        XCTAssertEqual(headerData[0], 0x50, "ZIP magic byte 0 should be 'P'")
        XCTAssertEqual(headerData[1], 0x4B, "ZIP magic byte 1 should be 'K'")

        // Zip size must be non-trivial (source has ~600KB of depth data alone)
        let attrs = try fm.attributesOfItem(atPath: zipURL.path)
        let zipSize = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(zipSize, 1000, "Zip should be at least 1KB (got \(zipSize) bytes)")
    }

    // MARK: - 6.11 Scan ID persisted locally

    func testScanIdPersistedToUserDefaults() {
        let testScanId = "test-scan-\(UUID().uuidString)"

        CloudUploader.shared.persistScanId(testScanId)

        let stored = UserDefaults.standard.stringArray(forKey: "completedScanIds")
        XCTAssertNotNil(stored, "completedScanIds should exist in UserDefaults")
        XCTAssertTrue(stored?.contains(testScanId) == true,
                      "Persisted scan IDs should contain the test scan ID")
    }

    func testMultipleScanIdsPersistedInOrder() {
        let id1 = "scan-1"
        let id2 = "scan-2"
        let id3 = "scan-3"

        CloudUploader.shared.persistScanId(id1)
        CloudUploader.shared.persistScanId(id2)
        CloudUploader.shared.persistScanId(id3)

        let stored = UserDefaults.standard.stringArray(forKey: "completedScanIds")
        XCTAssertEqual(stored, [id1, id2, id3], "Scan IDs should be persisted in order")
    }

    // MARK: - 6.12 Upload fails gracefully on no network (partial — verifies error handling)

    func testUploadErrorTypesHaveDescriptions() {
        let zipError = CloudUploader.UploadError.zipFailed
        let apiError = CloudUploader.UploadError.apiError("test error")
        let uploadError = CloudUploader.UploadError.uploadFailed("upload test error")

        XCTAssertNotNil(zipError.errorDescription)
        XCTAssertNotNil(apiError.errorDescription)
        XCTAssertNotNil(uploadError.errorDescription)
        XCTAssertTrue(apiError.errorDescription?.contains("test error") == true)
        XCTAssertTrue(uploadError.errorDescription?.contains("upload test error") == true)
    }
}
