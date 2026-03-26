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

        // Count mesh stats
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

            // JPEG
            let jpegURL = keyframesDir.appendingPathComponent("\(frameName).jpg")
            try frame.jpegData.write(to: jpegURL)

            // Per-frame JSON (camera pose + metadata)
            let frameJSON = frameMetadata(for: frame)
            let frameJSONURL = keyframesDir.appendingPathComponent("\(frameName).json")
            let jsonData = try JSONSerialization.data(withJSONObject: frameJSON, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: frameJSONURL)

            // Depth map
            if let depthData = frame.depthData {
                let depthURL = depthDir.appendingPathComponent("\(frameName).depth")
                try depthData.write(to: depthURL)
            }
        }

        // 3. Build metadata.json
        onProgress("Writing metadata...")
        let metadata = buildMetadata(
            keyframes: keyframes,
            meshVertexCount: totalVertices,
            meshFaceCount: totalFaces,
            scanDuration: scanDuration
        )
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        let metadataURL = scanDir.appendingPathComponent("metadata.json")
        try metadataData.write(to: metadataURL)

        // Calculate total size
        let totalSize = directorySize(url: scanDir)
        print("[RoomScanAlpha] Scan packaged at \(scanDir.path) — \(totalSize / 1024 / 1024)MB")

        return PackageResult(directoryURL: scanDir, totalSizeBytes: totalSize)
    }

    // MARK: - Private

    private static func frameMetadata(for frame: CapturedFrame) -> [String: Any] {
        let transform = frame.cameraTransform
        let transformArray: [Float] = [
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
            transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w,
        ]

        return [
            "index": frame.index,
            "timestamp": frame.timestamp,
            "camera_transform": transformArray,
            "image_width": frame.imageWidth,
            "image_height": frame.imageHeight,
            "depth_width": frame.depthWidth,
            "depth_height": frame.depthHeight,
        ]
    }

    private static func buildMetadata(
        keyframes: [CapturedFrame],
        meshVertexCount: Int,
        meshFaceCount: Int,
        scanDuration: TimeInterval
    ) -> [String: Any] {
        let device = UIDevice.current

        // Use first frame's intrinsics as reference
        let intrinsics: [String: Any]
        if let first = keyframes.first {
            let k = first.cameraIntrinsics
            intrinsics = [
                "fx": k[0][0],
                "fy": k[1][1],
                "cx": k[2][0],
                "cy": k[2][1],
            ]
        } else {
            intrinsics = [:]
        }

        let imageResolution: [String: Any]
        if let first = keyframes.first {
            imageResolution = ["width": first.imageWidth, "height": first.imageHeight]
        } else {
            imageResolution = [:]
        }

        let depthFormat: [String: Any]
        if let first = keyframes.first, first.depthData != nil {
            depthFormat = [
                "pixel_format": "kCVPixelFormatType_DepthFloat32",
                "width": first.depthWidth,
                "height": first.depthHeight,
                "byte_order": "little_endian",
            ]
        } else {
            depthFormat = [:]
        }

        let keyframeList: [[String: Any]] = keyframes.map { frame in
            let frameName = String(format: "frame_%03d", frame.index)
            return [
                "index": frame.index,
                "filename": "\(frameName).jpg",
                "depth_filename": "\(frameName).depth",
                "timestamp": frame.timestamp,
            ]
        }

        return [
            "device": device.model,
            "device_name": device.name,
            "ios_version": device.systemVersion,
            "scan_duration_seconds": round(scanDuration * 10) / 10,
            "camera_intrinsics": intrinsics,
            "image_resolution": imageResolution,
            "depth_format": depthFormat,
            "keyframe_count": keyframes.count,
            "mesh_vertex_count": meshVertexCount,
            "mesh_face_count": meshFaceCount,
            "keyframes": keyframeList,
        ]
    }

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
