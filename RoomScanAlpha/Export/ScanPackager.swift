// Bundles HEVC video, pose sidecar, depth sidecar, PLY mesh, and metadata into a scan package
// directory for cloud upload.

import ARKit
import UIKit

struct ScanPackager {

    struct PackageResult {
        let directoryURL: URL
        let totalSizeBytes: Int
    }

    enum PackageError: LocalizedError {
        case captureFinalizationFailed

        var errorDescription: String? {
            switch self {
            case .captureFinalizationFailed:
                return "Failed to finalize video capture"
            }
        }
    }

    /// Package a completed scan into the export directory structure.
    /// Must be called from a background thread.
    static func package(
        captureResult: CaptureResult,
        meshAnchors: [ARMeshAnchor],
        scanDuration: TimeInterval,
        rfqContext: RFQContext?,
        cornerAnnotation: CornerAnnotation?,
        roomScope: RoomScope? = nil,
        panoramicFrames: [CapturedFrame] = [],
        panoramaStartTransform: simd_float4x4? = nil,
        onProgress: @escaping (String) -> Void
    ) throws -> PackageResult {
        let timestamp = Int(Date().timeIntervalSince1970)
        let scanDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan_\(timestamp)")

        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)

        // 1. Export PLY mesh
        onProgress("Exporting mesh...")
        let plyURL = scanDir.appendingPathComponent("mesh.ply")
        let meshCounts = try PLYExporter.export(meshAnchors: meshAnchors, to: plyURL)

        // 2. Copy HEVC video + sidecar files (already on disk from VideoFrameWriter)
        onProgress("Copying video and metadata...")
        let videoDestURL = scanDir.appendingPathComponent("scan_video.mov")
        let poseDestURL = scanDir.appendingPathComponent("poses.jsonl")
        let depthDestURL = scanDir.appendingPathComponent("depth.bin")

        try FileManager.default.copyItem(at: captureResult.videoURL, to: videoDestURL)
        try FileManager.default.copyItem(at: captureResult.poseSidecarURL, to: poseDestURL)
        try FileManager.default.copyItem(at: captureResult.depthSidecarURL, to: depthDestURL)

        // 2b. Export panoramic frames (if available)
        if !panoramicFrames.isEmpty {
            onProgress("Exporting panoramic frames...")
            let panoDir = scanDir.appendingPathComponent("panoramic")
            let panoDepthDir = scanDir.appendingPathComponent("panoramic_depth")
            try FileManager.default.createDirectory(at: panoDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: panoDepthDir, withIntermediateDirectories: true)

            for frame in panoramicFrames {
                let frameName = String(format: "pano_%03d", frame.index)

                let jpegURL = panoDir.appendingPathComponent("\(frameName).jpg")
                try frame.jpegData.write(to: jpegURL)

                let frameJSON = FrameMetadata.from(frame)
                let frameJSONURL = panoDir.appendingPathComponent("\(frameName).json")
                let jsonData = try JSONEncoder.compact.encode(frameJSON)
                try jsonData.write(to: frameJSONURL)

                if let depthData = frame.depthData {
                    let depthURL = panoDepthDir.appendingPathComponent("\(frameName).depth")
                    try depthData.write(to: depthURL)
                }
            }
        }

        // 3. Build metadata.json
        onProgress("Writing metadata...")
        let metadata = ScanMetadata.build(
            captureResult: captureResult,
            meshVertexCount: meshCounts.vertexCount,
            meshFaceCount: meshCounts.faceCount,
            scanDuration: scanDuration,
            rfqContext: rfqContext,
            cornerAnnotation: cornerAnnotation,
            roomScope: roomScope,
            panoramicFrames: panoramicFrames,
            panoramaStartTransform: panoramaStartTransform
        )
        let metadataData = try JSONEncoder.prettyPrinted.encode(metadata)
        let metadataURL = scanDir.appendingPathComponent("metadata.json")
        try metadataData.write(to: metadataURL)

        let totalSize = directorySize(url: scanDir)
        print("[RoomScanAlpha] Scan packaged at \(scanDir.path) — \(totalSize / 1024 / 1024)MB (\(captureResult.frameCount) HEVC frames)")

        return PackageResult(directoryURL: scanDir, totalSizeBytes: totalSize)
    }

    /// Package supplemental scan data (mesh + keyframes from gap re-scan).
    /// Structurally identical to a regular scan package — same PLY + keyframe format.
    static func packageSupplemental(
        keyframes: [CapturedFrame],
        meshAnchors: [ARMeshAnchor],
        onProgress: @escaping (String) -> Void
    ) throws -> PackageResult {
        return try package(
            keyframes: keyframes,
            meshAnchors: meshAnchors,
            scanDuration: 0,
            rfqContext: nil,
            cornerAnnotation: nil,
            onProgress: onProgress
        )
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
    // Capture format
    let captureFormat: String

    // RFQ context
    let rfqId: String?
    let floorId: String?
    let roomLabel: String?
    let originX: Float?
    let originY: Float?
    let rotationDeg: Float?

    // Device & scan info
    let device: String
    let deviceName: String
    let iosVersion: String
    let scanDurationSeconds: Double
    let cameraIntrinsics: CameraIntrinsics
    let imageResolution: ImageResolution
    let depthFormat: DepthFormat
    let frameCount: Int
    let meshVertexCount: Int
    let meshFaceCount: Int
    let cornerAnnotation: CornerAnnotation?

    // HEVC-specific filenames
    let videoFilename: String
    let poseSidecarFilename: String
    let depthSidecarFilename: String

    // Scope of work
    let roomScope: RoomScope?

    // Panoramic sweep data
    let panoramicKeyframeCount: Int?
    let panoramaStartTransform: [Float]?
    let panoramicKeyframes: [KeyframeEntry]?

    enum CodingKeys: String, CodingKey {
        case captureFormat = "capture_format"
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
        case frameCount = "frame_count"
        case meshVertexCount = "mesh_vertex_count"
        case meshFaceCount = "mesh_face_count"
        case cornerAnnotation = "corner_annotation"
        case videoFilename = "video_filename"
        case poseSidecarFilename = "pose_sidecar_filename"
        case depthSidecarFilename = "depth_sidecar_filename"
        case roomScope = "room_scope"
        case panoramicKeyframeCount = "panoramic_keyframe_count"
        case panoramaStartTransform = "panorama_start_transform"
        case panoramicKeyframes = "panoramic_keyframes"
    }

    static func build(
        captureResult: CaptureResult,
        meshVertexCount: Int,
        meshFaceCount: Int,
        scanDuration: TimeInterval,
        rfqContext: RFQContext?,
        cornerAnnotation: CornerAnnotation?,
        roomScope: RoomScope? = nil,
        panoramicFrames: [CapturedFrame] = [],
        panoramaStartTransform: simd_float4x4? = nil
    ) -> ScanMetadata {
        let device = UIDevice.current

        // Flatten panorama start transform to 16-float array (column-major)
        var startTransformArray: [Float]?
        if let t = panoramaStartTransform {
            startTransformArray = [
                t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
                t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
                t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
                t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w,
            ]
        }

        return ScanMetadata(
            captureFormat: "hevc",
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
            cameraIntrinsics: CameraIntrinsics.from(captureResult.firstFrameIntrinsics),
            imageResolution: ImageResolution(
                width: captureResult.imageWidth,
                height: captureResult.imageHeight
            ),
            depthFormat: DepthFormat(
                pixelFormat: captureResult.depthWidth > 0 ? "kCVPixelFormatType_DepthFloat32" : "",
                width: captureResult.depthWidth,
                height: captureResult.depthHeight,
                byteOrder: captureResult.depthWidth > 0 ? "little_endian" : ""
            ),
            frameCount: captureResult.frameCount,
            meshVertexCount: meshVertexCount,
            meshFaceCount: meshFaceCount,
            cornerAnnotation: cornerAnnotation,
            videoFilename: "scan_video.mov",
            poseSidecarFilename: "poses.jsonl",
            depthSidecarFilename: "depth.bin",
            roomScope: roomScope,
            panoramicKeyframeCount: panoramicFrames.isEmpty ? nil : panoramicFrames.count,
            panoramaStartTransform: startTransformArray,
            panoramicKeyframes: panoramicFrames.isEmpty ? nil : panoramicFrames.map {
                let name = String(format: "pano_%03d", $0.index)
                let t = $0.cameraTransform
                return KeyframeEntry(
                    index: $0.index,
                    filename: "\(name).jpg",
                    depthFilename: "\(name).depth",
                    timestamp: $0.timestamp,
                    position: [t.columns.3.x, t.columns.3.y, t.columns.3.z]
                )
            }
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
}

struct KeyframeEntry: Codable {
    let index: Int
    let filename: String
    let depthFilename: String
    let timestamp: TimeInterval
    let position: [Float]?

    enum CodingKeys: String, CodingKey {
        case index, filename, timestamp, position
        case depthFilename = "depth_filename"
    }
}

// MARK: - JSONEncoder convenience

extension JSONEncoder {
    static let prettyPrinted: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let compact: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
