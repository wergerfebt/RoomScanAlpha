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

    private var scanStartTime: Date?

    func startScan() {
        meshTriangleCount = 0
        meshAnchorCount = 0
        keyframeCount = 0
        exportProgress = ""
        exportError = nil
        lastExportURL = nil
        showQualityWarning = false
        scanStartTime = Date()
        state = .scanning
    }

    func stopScan() {
        state = .idle
    }

    var scanDuration: TimeInterval {
        guard let start = scanStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

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
}
