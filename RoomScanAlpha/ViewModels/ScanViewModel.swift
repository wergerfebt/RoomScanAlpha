import SwiftUI
import ARKit

@Observable
final class ScanViewModel {
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

    // Upload state
    var uploadProgress: Double = 0.0
    var uploadStatus: String = ""
    var uploadError: String?
    var lastScanId: String?

    // Result state
    var scanResult: CloudUploader.ScanResult?

    // RFQ context
    var selectedRFQ: RFQ?
    var roomLabel: String = ""
    var rfqContext: RFQContext?

    // History
    var showHistory = false

    // Error recovery
    var showInterruptionAlert = false
    var showLowStorageAlert = false

    private var scanStartTime: Date?

    var hasRFQSelected: Bool {
        selectedRFQ != nil
    }

    func startScan() {
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
        scanStartTime = Date()
        state = .scanning
    }

    func stopScan() {
        state = .idle
    }

    /// Build RFQ context from current state + AR session world origin.
    func buildRFQContext(worldTransform: simd_float4x4) {
        guard let rfq = selectedRFQ else { return }

        let position = worldTransform.columns.3
        // Extract Y rotation (heading) from the transform matrix
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

    // Minimum quality: 15 keyframes provides enough views for ORB feature matching;
    // 500 triangles ensures the mesh covers more than a single small surface.
    var scanQualitySufficient: Bool {
        keyframeCount >= 15 && meshTriangleCount >= 500
    }

    func updateMeshStats(triangleCount: Int, anchorCount: Int) {
        meshTriangleCount = triangleCount
        meshAnchorCount = anchorCount
    }

    func updateKeyframeCount(_ count: Int) {
        keyframeCount = count
    }

    /// Check if device has at least 200MB free before export.
    var hasEnoughStorage: Bool {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let path = paths.first else { return true }
        let values = try? path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return available > 200 * 1024 * 1024 // 200MB
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
