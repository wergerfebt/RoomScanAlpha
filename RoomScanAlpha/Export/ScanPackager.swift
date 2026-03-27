// Bundles keyframes, PLY mesh, depth maps, and metadata into a scan package directory for cloud upload.

import ARKit
import UIKit

struct ScanPackager {

    struct PackageResult {
        let directoryURL: URL
        let totalSizeBytes: Int
    }

    /// Package a completed scan into the export directory structure.
    /// Must be called from a background thread.
    static func package(
        keyframes: [CapturedFrame],
        meshAnchors: [ARMeshAnchor],
        scanDuration: TimeInterval,
        rfqContext: RFQContext?,
        onProgress: @escaping (String) -> Void
    ) throws -> PackageResult {
        let timestamp = Int(Date().timeIntervalSince1970)
        let scanDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan_\(timestamp)")
        let keyframesDir = scanDir.appendingPathComponent("keyframes")
        let depthDir = scanDir.appendingPathComponent("depth")

        try FileManager.default.createDirectory(at: keyframesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depthDir, withIntermediateDirectories: true)

        // 1. Export PLY mesh
        onProgress("Exporting mesh...")
        let plyURL = scanDir.appendingPathComponent("mesh.ply")
        try PLYExporter.export(meshAnchors: meshAnchors, to: plyURL)

        var totalVertices = 0
        var totalFaces = 0
        for anchor in meshAnchors {
            totalVertices += anchor.geometry.vertices.count
            totalFaces += anchor.geometry.faces.count
        }

        // 2. Export keyframes (JPEG + per-frame JSON) and depth maps
        onProgress("Exporting keyframes...")
        for frame in keyframes {
            let frameName = String(format: "frame_%03d", frame.index)

            let jpegURL = keyframesDir.appendingPathComponent("\(frameName).jpg")
            try frame.jpegData.write(to: jpegURL)

            let frameJSON = FrameMetadata.from(frame)
            let frameJSONURL = keyframesDir.appendingPathComponent("\(frameName).json")
            let jsonData = try JSONEncoder.prettyPrinted.encode(frameJSON)
            try jsonData.write(to: frameJSONURL)

            if let depthData = frame.depthData {
                let depthURL = depthDir.appendingPathComponent("\(frameName).depth")
                try depthData.write(to: depthURL)
            }
        }

        // 3. Build metadata.json
        onProgress("Writing metadata...")
        let metadata = ScanMetadata.build(
            keyframes: keyframes,
            meshVertexCount: totalVertices,
            meshFaceCount: totalFaces,
            scanDuration: scanDuration,
            rfqContext: rfqContext
        )
        let metadataData = try JSONEncoder.prettyPrinted.encode(metadata)
        let metadataURL = scanDir.appendingPathComponent("metadata.json")
        try metadataData.write(to: metadataURL)

        let totalSize = directorySize(url: scanDir)
        print("[RoomScanAlpha] Scan packaged at \(scanDir.path) — \(totalSize / 1024 / 1024)MB")

        return PackageResult(directoryURL: scanDir, totalSizeBytes: totalSize)
    }

    // MARK: - Private

    private static func directorySize(url: URL) -> Int {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let fileURL = files?.nextObject() as? URL {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
        }
        return total
    }
}

// MARK: - Metadata schema

struct ScanMetadata: Codable {
    // RFQ context (nil before Phase 8 wiring)
    let rfqId: String?
    let floorId: String?
    let roomLabel: String?
    let originX: Float?       // meters — AR world space
    let originY: Float?       // meters — AR world space
    let rotationDeg: Float?   // degrees

    // Device & scan info
    let device: String
    let deviceName: String
    let iosVersion: String
    let scanDurationSeconds: Double
    let cameraIntrinsics: CameraIntrinsics
    let imageResolution: ImageResolution
    let depthFormat: DepthFormat
    let keyframeCount: Int
    let meshVertexCount: Int
    let meshFaceCount: Int
    let keyframes: [KeyframeEntry]

    enum CodingKeys: String, CodingKey {
        case rfqId = "rfq_id"
        case floorId = "floor_id"
        case roomLabel = "room_label"
        case originX = "origin_x"
        case originY = "origin_y"
        case rotationDeg = "rotation_deg"
        case device
        case deviceName = "device_name"
        case iosVersion = "ios_version"
        case scanDurationSeconds = "scan_duration_seconds"
        case cameraIntrinsics = "camera_intrinsics"
        case imageResolution = "image_resolution"
        case depthFormat = "depth_format"
        case keyframeCount = "keyframe_count"
        case meshVertexCount = "mesh_vertex_count"
        case meshFaceCount = "mesh_face_count"
        case keyframes
    }

    static func build(
        keyframes: [CapturedFrame],
        meshVertexCount: Int,
        meshFaceCount: Int,
        scanDuration: TimeInterval,
        rfqContext: RFQContext?
    ) -> ScanMetadata {
        let device = UIDevice.current
        let firstFrame = keyframes.first

        return ScanMetadata(
            rfqId: rfqContext?.rfqId,
            floorId: rfqContext?.floorId,
            roomLabel: rfqContext?.roomLabel,
            originX: rfqContext?.originX,
            originY: rfqContext?.originY,
            rotationDeg: rfqContext?.rotationDeg,
            device: device.model,
            deviceName: device.name,
            iosVersion: device.systemVersion,
            scanDurationSeconds: round(scanDuration * 10) / 10,
            cameraIntrinsics: CameraIntrinsics.from(firstFrame?.cameraIntrinsics),
            imageResolution: ImageResolution(
                width: firstFrame?.imageWidth ?? 0,
                height: firstFrame?.imageHeight ?? 0
            ),
            depthFormat: DepthFormat.from(firstFrame),
            keyframeCount: keyframes.count,
            meshVertexCount: meshVertexCount,
            meshFaceCount: meshFaceCount,
            keyframes: keyframes.map { KeyframeEntry.from($0) }
        )
    }
}

struct CameraIntrinsics: Codable {
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float

    static func from(_ matrix: simd_float3x3?) -> CameraIntrinsics {
        guard let k = matrix else { return CameraIntrinsics(fx: 0, fy: 0, cx: 0, cy: 0) }
        return CameraIntrinsics(fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1])
    }
}

struct ImageResolution: Codable {
    let width: Int
    let height: Int
}

struct DepthFormat: Codable {
    let pixelFormat: String
    let width: Int
    let height: Int
    let byteOrder: String

    enum CodingKeys: String, CodingKey {
        case pixelFormat = "pixel_format"
        case width, height
        case byteOrder = "byte_order"
    }

    static func from(_ frame: CapturedFrame?) -> DepthFormat {
        guard let frame = frame, frame.depthData != nil else {
            return DepthFormat(pixelFormat: "", width: 0, height: 0, byteOrder: "")
        }
        return DepthFormat(
            pixelFormat: "kCVPixelFormatType_DepthFloat32",
            width: frame.depthWidth,
            height: frame.depthHeight,
            byteOrder: "little_endian"
        )
    }
}

struct KeyframeEntry: Codable {
    let index: Int
    let filename: String
    let depthFilename: String
    let timestamp: TimeInterval

    enum CodingKeys: String, CodingKey {
        case index, filename, timestamp
        case depthFilename = "depth_filename"
    }

    static func from(_ frame: CapturedFrame) -> KeyframeEntry {
        let name = String(format: "frame_%03d", frame.index)
        return KeyframeEntry(
            index: frame.index,
            filename: "\(name).jpg",
            depthFilename: "\(name).depth",
            timestamp: frame.timestamp
        )
    }
}

struct FrameMetadata: Codable {
    let index: Int
    let timestamp: TimeInterval
    let cameraTransform: [Float]
    let imageWidth: Int
    let imageHeight: Int
    let depthWidth: Int
    let depthHeight: Int

    enum CodingKeys: String, CodingKey {
        case index, timestamp
        case cameraTransform = "camera_transform"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case depthWidth = "depth_width"
        case depthHeight = "depth_height"
    }

    static func from(_ frame: CapturedFrame) -> FrameMetadata {
        let t = frame.cameraTransform
        let transformArray: [Float] = [
            t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
            t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
            t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
            t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w,
        ]

        return FrameMetadata(
            index: frame.index,
            timestamp: frame.timestamp,
            cameraTransform: transformArray,
            imageWidth: frame.imageWidth,
            imageHeight: frame.imageHeight,
            depthWidth: frame.depthWidth,
            depthHeight: frame.depthHeight
        )
    }
}

// MARK: - JSONEncoder convenience

extension JSONEncoder {
    static let prettyPrinted: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
