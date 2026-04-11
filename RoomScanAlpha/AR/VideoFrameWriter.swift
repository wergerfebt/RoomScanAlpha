// Writes ARKit camera frames to an HEVC video file with companion pose and depth sidecar files.
// All data is streamed directly to disk — no frame data is held in memory.
// Depth writes happen on a background queue to avoid blocking the AR delegate thread.

import AVFoundation
import ARKit
import VideoToolbox
import simd

/// Result of a completed video capture session: file URLs for the HEVC video,
/// JSONL pose sidecar, and binary depth sidecar.
struct CaptureResult {
    let videoURL: URL
    let poseSidecarURL: URL
    let depthSidecarURL: URL
    let frameCount: Int
    let depthFrameCount: Int
    let firstFrameIntrinsics: simd_float3x3?
    let imageWidth: Int
    let imageHeight: Int
    let depthWidth: Int
    let depthHeight: Int
}

final class VideoFrameWriter {

    // MARK: - State

    private(set) var frameCount: Int = 0
    private(set) var depthFrameCount: Int = 0
    private(set) var hasFailed: Bool = false

    /// Write depth every Nth video frame. 1 = every frame (needed for 3DGS gradient backprop).
    let depthInterval: Int

    private let videoURL: URL
    private let poseSidecarURL: URL
    private let depthSidecarURL: URL

    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var poseFileHandle: FileHandle?
    private var depthFileHandle: FileHandle?

    /// Background queue for depth writes — keeps AR delegate thread unblocked.
    /// userInitiated QoS needed to keep up with every-frame depth at 10fps (~1.9MB/s).
    private let depthQueue = DispatchQueue(label: "com.roomscan.depth-writer", qos: .userInitiated)

    /// First frame's intrinsics — used for metadata.json (all frames share the same camera).
    private var firstIntrinsics: simd_float3x3?
    private var imageWidth: Int = 0
    private var imageHeight: Int = 0
    private var depthWidth: Int = 0
    private var depthHeight: Int = 0

    /// Byte offset into the depth sidecar for the next frame.
    private var depthByteOffset: Int = 0

    /// First frame's ARKit timestamp — subtracted from all subsequent timestamps
    /// so the video starts at t=0 instead of t=device_uptime.
    private var firstTimestamp: TimeInterval = 0

    /// Whether startWriting() has been called on the asset writer.
    private var isWriting = false

    // MARK: - Depth Sidecar Header

    /// 16-byte header: "DPTH" magic (4) + version uint32 (4) + frame count uint32 (4) + bytes per frame uint32 (4).
    /// Frame count is patched in finishWriting() once the final count is known.
    private static let depthHeaderSize = 16
    private static let depthMagic: [UInt8] = [0x44, 0x50, 0x54, 0x48] // "DPTH"
    private static let depthVersion: UInt32 = 1

    // MARK: - Init

    /// - Parameter depthInterval: Write depth every Nth video frame (default 1 = every frame).
    init(depthInterval: Int = 1) {
        self.depthInterval = depthInterval
        let tmp = FileManager.default.temporaryDirectory
        let id = UUID().uuidString.prefix(8)
        videoURL = tmp.appendingPathComponent("scan_\(id).mov")
        poseSidecarURL = tmp.appendingPathComponent("scan_\(id)_poses.jsonl")
        depthSidecarURL = tmp.appendingPathComponent("scan_\(id)_depth.bin")
    }

    // MARK: - Public

    /// Append a frame from ARKit to the HEVC video and pose sidecar.
    /// Depth is written every `depthInterval` frames on a background queue.
    /// Returns true if the frame was successfully appended.
    /// Thread safety: call from a single serial queue (the AR session delegate queue).
    @discardableResult
    func appendFrame(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        transform: simd_float4x4,
        intrinsics: simd_float3x3,
        depthMap: CVPixelBuffer?
    ) -> Bool {
        guard !hasFailed else { return false }

        // Lazy initialization on first frame — we need the pixel buffer dimensions.
        if assetWriter == nil {
            do {
                try setupWriter(pixelBuffer: pixelBuffer)
            } catch {
                print("[RoomScanAlpha] VideoFrameWriter setup failed: \(error)")
                hasFailed = true
                return false
            }
        }

        guard let writer = assetWriter,
              let input = writerInput,
              let adaptor = pixelBufferAdaptor,
              writer.status == .writing else {
            if assetWriter?.status == .failed {
                print("[RoomScanAlpha] AVAssetWriter failed: \(assetWriter?.error?.localizedDescription ?? "unknown")")
                hasFailed = true
            }
            return false
        }

        // Skip if the encoder isn't ready — don't block the AR thread.
        guard input.isReadyForMoreMediaData else { return false }

        // Record first frame metadata and capture depth dimensions eagerly.
        if frameCount == 0 {
            firstTimestamp = timestamp
            firstIntrinsics = intrinsics
            imageWidth = CVPixelBufferGetWidth(pixelBuffer)
            imageHeight = CVPixelBufferGetHeight(pixelBuffer)
            // Set depth dimensions from the first depth map so pose entries have correct dw/dh.
            if let depthMap = depthMap {
                depthWidth = CVPixelBufferGetWidth(depthMap)
                depthHeight = CVPixelBufferGetHeight(depthMap)
            }
        }

        // Offset timestamp relative to first frame so video starts at t=0
        // instead of t=device_uptime (which can be 80+ hours).
        let relativeTime = timestamp - firstTimestamp
        let cmTime = CMTime(seconds: relativeTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

        // Append video frame.
        guard adaptor.append(pixelBuffer, withPresentationTime: cmTime) else {
            if writer.status == .failed { hasFailed = true }
            return false
        }

        // Write pose entry to JSONL sidecar (lightweight string write — OK on AR thread).
        writePoseEntry(index: frameCount, timestamp: timestamp, transform: transform, intrinsics: intrinsics)

        // Write depth on background queue every Nth frame to reduce AR thread I/O.
        if let depthMap = depthMap, frameCount % depthInterval == 0 {
            // Copy depth bytes while we still have the lock, then dispatch write.
            let depthCopy = copyDepthBuffer(depthMap)
            if let depthCopy = depthCopy {
                depthByteOffset += depthCopy.count
                depthFrameCount += 1

                if depthFrameCount == 1 {
                    // First depth frame — patch the bytes_per_frame header field.
                    if depthWidth == 0 {
                        depthWidth = CVPixelBufferGetWidth(depthMap)
                        depthHeight = CVPixelBufferGetHeight(depthMap)
                    }
                    patchDepthBytesPerFrame(UInt32(depthCopy.count))
                }

                depthQueue.async { [weak self] in
                    self?.depthFileHandle?.write(depthCopy)
                }
            }
        }

        frameCount += 1
        return true
    }

    /// Finalize the video file and sidecar files. Must be called when capture ends.
    func finishWriting() async -> CaptureResult? {
        guard let writer = assetWriter, writer.status == .writing else {
            cleanup()
            return nil
        }

        writerInput?.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        // Wait for any pending depth writes to complete.
        depthQueue.sync {}

        // Patch depth sidecar header with final frame count.
        patchDepthHeader()

        // Close file handles.
        try? poseFileHandle?.close()
        try? depthFileHandle?.close()
        poseFileHandle = nil
        depthFileHandle = nil

        guard writer.status == .completed else {
            print("[RoomScanAlpha] AVAssetWriter finished with status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "")")
            cleanup()
            return nil
        }

        let videoSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
        let depthSize = (try? FileManager.default.attributesOfItem(atPath: depthSidecarURL.path)[.size] as? Int) ?? 0
        print("[RoomScanAlpha] HEVC video: \(frameCount) frames, \(videoSize / 1024)KB — depth: \(depthFrameCount) frames, \(depthSize / 1024)KB")

        return CaptureResult(
            videoURL: videoURL,
            poseSidecarURL: poseSidecarURL,
            depthSidecarURL: depthSidecarURL,
            frameCount: frameCount,
            depthFrameCount: depthFrameCount,
            firstFrameIntrinsics: firstIntrinsics,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            depthWidth: depthWidth,
            depthHeight: depthHeight
        )
    }

    /// Clean up temporary files if the capture is abandoned.
    func cleanup() {
        depthQueue.sync {}
        try? poseFileHandle?.close()
        try? depthFileHandle?.close()
        poseFileHandle = nil
        depthFileHandle = nil
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: poseSidecarURL)
        try? FileManager.default.removeItem(at: depthSidecarURL)
    }

    // MARK: - Private: Setup

    private func setupWriter(pixelBuffer: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,         // 4 Mbps — room for 10fps continuous
                AVVideoExpectedSourceFrameRateKey: 10,        // ~10fps continuous capture
                AVVideoMaxKeyFrameIntervalKey: 30,            // I-frame every 3 seconds
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(pixelBuffer),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )

        guard writer.canAdd(input) else {
            throw VideoWriterError.cannotAddInput
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.assetWriter = writer
        self.writerInput = input
        self.pixelBufferAdaptor = adaptor
        self.isWriting = true

        // Create sidecar files.
        FileManager.default.createFile(atPath: poseSidecarURL.path, contents: nil)
        poseFileHandle = try FileHandle(forWritingTo: poseSidecarURL)

        // Write depth sidecar header (frame count placeholder = 0, patched in finishWriting).
        var header = Data(Self.depthMagic)
        var version = Self.depthVersion
        header.append(Data(bytes: &version, count: 4))
        var count: UInt32 = 0 // placeholder
        header.append(Data(bytes: &count, count: 4))
        var bytesPerFrame: UInt32 = 0 // set on first depth frame
        header.append(Data(bytes: &bytesPerFrame, count: 4))
        FileManager.default.createFile(atPath: depthSidecarURL.path, contents: header)
        depthFileHandle = try FileHandle(forWritingTo: depthSidecarURL)
        depthFileHandle?.seekToEndOfFile()
        depthByteOffset = Self.depthHeaderSize

        print("[RoomScanAlpha] VideoFrameWriter initialized: \(width)×\(height) HEVC @ ~10fps → \(videoURL.lastPathComponent)")
    }

    // MARK: - Private: Pose Sidecar

    private func writePoseEntry(
        index: Int,
        timestamp: TimeInterval,
        transform: simd_float4x4,
        intrinsics: simd_float3x3
    ) {
        let t = transform
        // Column-major 16-float array matching the existing per-frame JSON format.
        let tx = "[\(t.columns.0.x),\(t.columns.0.y),\(t.columns.0.z),\(t.columns.0.w)," +
                 "\(t.columns.1.x),\(t.columns.1.y),\(t.columns.1.z),\(t.columns.1.w)," +
                 "\(t.columns.2.x),\(t.columns.2.y),\(t.columns.2.z),\(t.columns.2.w)," +
                 "\(t.columns.3.x),\(t.columns.3.y),\(t.columns.3.z),\(t.columns.3.w)]"

        // "do" = -1 means no depth for this frame; >= 0 = byte offset into depth.bin
        let hasDepth = (index % depthInterval == 0)
        let depthOffsetValue = hasDepth ? depthByteOffset : -1

        let line = "{\"i\":\(index),\"t\":\(timestamp),\"tx\":\(tx)," +
                   "\"fx\":\(intrinsics[0][0]),\"fy\":\(intrinsics[1][1])," +
                   "\"cx\":\(intrinsics[2][0]),\"cy\":\(intrinsics[2][1])," +
                   "\"w\":\(imageWidth),\"h\":\(imageHeight)," +
                   "\"dw\":\(depthWidth),\"dh\":\(depthHeight)," +
                   "\"do\":\(depthOffsetValue)}\n"

        if let data = line.data(using: .utf8) {
            poseFileHandle?.write(data)
        }
    }

    // MARK: - Private: Depth

    /// Copy depth buffer bytes while the buffer is accessible. Returns owned Data.
    private func copyDepthBuffer(_ pixelBuffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return Data(bytes: baseAddress, count: bytesPerRow * height)
    }

    private func patchDepthBytesPerFrame(_ bytesPerFrame: UInt32) {
        guard let handle = depthFileHandle else { return }
        let currentPos = handle.offsetInFile
        handle.seek(toFileOffset: 12)
        var value = bytesPerFrame
        handle.write(Data(bytes: &value, count: 4))
        handle.seek(toFileOffset: currentPos)
    }

    private func patchDepthHeader() {
        guard let handle = depthFileHandle else { return }
        // Patch frame_count at offset 8 with actual depth frame count.
        handle.seek(toFileOffset: 8)
        var count = UInt32(depthFrameCount)
        handle.write(Data(bytes: &count, count: 4))
    }

    // MARK: - Errors

    enum VideoWriterError: LocalizedError {
        case cannotAddInput

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: return "Cannot add video input to AVAssetWriter"
            }
        }
    }
}
