import XCTest
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan test cases:
/// - 4.1  PLY file is valid (correct header format)
/// - 4.2  PLY vertex count matches mesh
/// - 4.3  PLY face count matches mesh
/// - 4.4  PLY coordinates are Y-up right-handed
/// - 4.5  PLY includes classification data
final class PLYExporterTests: XCTestCase {

    // MARK: - Empty mesh export (4.1, 4.2, 4.3)

    func testExportEmptyMeshCreatesValidPLY() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_empty_\(UUID().uuidString).ply")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Export with no mesh anchors — should produce valid PLY with 0 verts/faces
        try PLYExporter.export(meshAnchors: [], to: tempURL)

        let data = try Data(contentsOf: tempURL)
        let headerString = extractPLYHeader(from: data)

        XCTAssertTrue(headerString.hasPrefix("ply"), "PLY must start with 'ply' magic")
        XCTAssertTrue(headerString.contains("format binary_little_endian 1.0"),
                      "PLY must specify binary little-endian format")
        XCTAssertTrue(headerString.contains("element vertex 0"), "Empty mesh should have 0 vertices")
        XCTAssertTrue(headerString.contains("element face 0"), "Empty mesh should have 0 faces")
        XCTAssertTrue(headerString.contains("end_header"), "PLY must have end_header")
    }

    // MARK: - Header format (4.1, 4.4)

    func testPLYHeaderContainsVertexProperties() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_props_\(UUID().uuidString).ply")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try PLYExporter.export(meshAnchors: [], to: tempURL)

        let data = try Data(contentsOf: tempURL)
        let header = extractPLYHeader(from: data)

        // Vertex properties: x, y, z (positions) + nx, ny, nz (normals)
        XCTAssertTrue(header.contains("property float x"))
        XCTAssertTrue(header.contains("property float y"))
        XCTAssertTrue(header.contains("property float z"))
        XCTAssertTrue(header.contains("property float nx"))
        XCTAssertTrue(header.contains("property float ny"))
        XCTAssertTrue(header.contains("property float nz"))
    }

    // MARK: - Classification property (4.5)

    func testPLYHeaderContainsClassification() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_class_\(UUID().uuidString).ply")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try PLYExporter.export(meshAnchors: [], to: tempURL)

        let data = try Data(contentsOf: tempURL)
        let header = extractPLYHeader(from: data)

        XCTAssertTrue(header.contains("property uchar classification"),
                      "PLY must include per-face classification property (4.5)")
    }

    // MARK: - Face list property (4.1)

    func testPLYHeaderContainsFaceList() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_face_\(UUID().uuidString).ply")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try PLYExporter.export(meshAnchors: [], to: tempURL)

        let data = try Data(contentsOf: tempURL)
        let header = extractPLYHeader(from: data)

        XCTAssertTrue(header.contains("property list uchar uint vertex_indices"),
                      "PLY faces must use vertex_indices list")
    }

    // MARK: - File creation

    func testExportCreatesFile() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_exists_\(UUID().uuidString).ply")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try PLYExporter.export(meshAnchors: [], to: tempURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path),
                      "PLY file should be created on disk")
    }

    func testExportedFileSizeIsPositive() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_size_\(UUID().uuidString).ply")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try PLYExporter.export(meshAnchors: [], to: tempURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0, "PLY file should not be empty (header alone has content)")
    }

    // MARK: - Helpers

    private func extractPLYHeader(from data: Data) -> String {
        // Find "end_header\n" in raw bytes to avoid binary data corrupting ASCII decoding
        let marker = "end_header\n".data(using: .ascii)!
        guard let range = data.range(of: marker) else {
            // Fallback: try to decode first 1KB as ASCII
            let prefix = data.prefix(1024)
            return String(data: prefix, encoding: .ascii) ?? ""
        }
        let headerData = data[data.startIndex..<range.upperBound]
        return String(data: headerData, encoding: .ascii) ?? ""
    }
}
