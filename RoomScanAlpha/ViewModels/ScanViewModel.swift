import SwiftUI
import ARKit

/// Orchestrates the room scan lifecycle: AR capture, export, upload, and result polling.
///
/// Owns all scan session state and is the single source of truth for what ContentView displays.
/// State transitions follow the `ScanState` enum — see its documentation for the valid graph.
@Observable
final class ScanViewModel {
    // MARK: - Scan Quality Thresholds

    /// Minimum keyframes for reliable ORB feature matching across viewpoints.
    static let minKeyframes = 15
    /// Minimum mesh faces to ensure the mesh covers more than a single small surface.
    static let minMeshTriangles = 500
    /// Minimum free disk space (in bytes) required before exporting a scan package.
    static let minStorageBytes: Int64 = 200 * 1024 * 1024  // 200 MB

    // MARK: - Scan State

    var state: ScanState = .idle
    var meshTriangleCount: Int = 0
    var meshAnchorCount: Int = 0
    var keyframeCount: Int = 0
    var exportProgress: String = ""
    var exportError: String?
    var lastExportURL: URL?
    var showQualityWarning: Bool = false
    var showCellularWarning: Bool = false
    var pendingUploadURL: URL?

    // MARK: - Upload State

    var uploadProgress: Double = 0.0
    var uploadStatus: String = ""
    var uploadError: String?
    var lastScanId: String?

    // MARK: - Result State

    var scanResult: CloudUploader.ScanResult?

    // MARK: - Annotation State

    var cornerAnnotation: CornerAnnotation?

    // MARK: - Panorama State

    /// Camera transform at the start of the panoramic sweep (facing corner 0).
    var panoramaStartTransform: simd_float4x4?
    /// Number of panoramic frames captured during the sweep.
    var panoramaFrameCount: Int = 0

    // MARK: - RFQ Context

    var selectedRFQ: RFQ?
    var roomLabel: String = ""
    var rfqContext: RFQContext?

    // MARK: - UI Flags

    var showHistory = false
    var showInterruptionAlert = false
    var showLowStorageAlert = false

    private var scanStartTime: Date?

    var hasRFQSelected: Bool {
        selectedRFQ != nil
    }

    /// Reset all scan session state and transition to the pre-scan ready state.
    /// The AR preview is visible but capture has not started.
    func prepareScan() {
        meshTriangleCount = 0
        meshAnchorCount = 0
        keyframeCount = 0
        exportProgress = ""
        exportError = nil
        lastExportURL = nil
        showQualityWarning = false
        uploadProgress = 0.0
        uploadStatus = ""
        uploadError = nil
        lastScanId = nil
        scanResult = nil
        roomLabel = ""
        rfqContext = nil
        cornerAnnotation = nil
        panoramaStartTransform = nil
        panoramaFrameCount = 0
        scanStartTime = nil
        state = .scanReady
    }

    /// Begin AR capture. Transitions from scanReady → scanning.
    func startScan() {
        scanStartTime = Date()
        state = .scanning
    }

    /// Stop capturing and transition to corner annotation.
    /// The AR session stays running — mesh reconstruction continues.
    func stopScan() {
        state = .annotatingCorners
    }

    /// Clear all captured data and return to the pre-scan ready state.
    func redoScan() {
        meshTriangleCount = 0
        meshAnchorCount = 0
        keyframeCount = 0
        exportProgress = ""
        exportError = nil
        lastExportURL = nil
        showQualityWarning = false
        cornerAnnotation = nil
        panoramaStartTransform = nil
        panoramaFrameCount = 0
        scanStartTime = nil
        state = .scanReady
    }

    /// Return to idle (used by Done buttons, error recovery, etc.)
    func returnToIdle() {
        state = .idle
    }

    /// Build RFQ context from current state + AR session world origin.
    /// Origin coordinates are stored in meters (ARKit's native unit).
    func buildRFQContext(worldTransform: simd_float4x4) {
        guard let rfq = selectedRFQ else { return }

        let position = worldTransform.columns.3
        // Extract Y-axis rotation (heading/yaw) from the transform matrix.
        // The X-axis basis vector (column 0) projected onto the XZ plane gives the
        // forward direction; atan2(z, x) yields the heading angle.
        let rotationRad = atan2(worldTransform.columns.0.z, worldTransform.columns.0.x)
        let rotationDeg = rotationRad * 180.0 / .pi

        rfqContext = RFQContext(
            rfqId: rfq.id,
            rfqDescription: rfq.description,
            floorId: UUID().uuidString,  // Alpha: auto-generate floor ID per scan
            roomLabel: roomLabel,
            originX: position.x,          // meters
            originY: position.y,          // meters
            rotationDeg: rotationDeg
        )
    }

    var scanDuration: TimeInterval {
        guard let start = scanStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var scanQualitySufficient: Bool {
        keyframeCount >= Self.minKeyframes && meshTriangleCount >= Self.minMeshTriangles
    }

    func updateMeshStats(triangleCount: Int, anchorCount: Int) {
        meshTriangleCount = triangleCount
        meshAnchorCount = anchorCount
    }

    func updateKeyframeCount(_ count: Int) {
        keyframeCount = count
    }

    /// Check if device has enough free disk space for the export package.
    var hasEnoughStorage: Bool {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let path = paths.first else { return true }
        let values = try? path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return available > Self.minStorageBytes
    }

    func saveToHistory(scanId: String, status: String) {
        let record = ScanRecord(
            id: scanId,
            rfqId: selectedRFQ?.id ?? "",
            rfqDescription: selectedRFQ?.description,
            roomLabel: roomLabel,
            status: status,
            keyframeCount: keyframeCount,
            meshTriangleCount: meshTriangleCount,
            timestamp: Date()
        )
        ScanHistoryStore.shared.save(record)
    }
}
