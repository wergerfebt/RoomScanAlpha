import SwiftUI
import ARKit

/// Movement coaching shown during scan. Drives `ScanCoachOverlay` copy.
enum ScanCoachingState: String, Equatable {
    case getStarted
    case walkSlowly
    case keepMoving
    case enoughCoverage
}

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
    var roomScope: RoomScope?

    // MARK: - Coverage Analysis

    var uncoveredFaces: [UUID: Set<Int>] = [:]
    var coverageRatio: Float = 0.0
    var isAnalyzingCoverage: Bool = false
    /// World-space vertex triangles for the inline coverage AR overlay. Adapter over
    /// `uncoveredFaces` that reuses the `GapRescanView` overlay-mesh builder.
    var localUncoveredFaces: [CloudUploader.UncoveredFace] = []
    /// Total faces analyzed in the most recent coverage pass — used for the uncovered-count display.
    var localUncoveredCount: Int = 0
    /// Enclosure-based "room completeness" — 0..1 fraction of the 6 room-shell
    /// directions where the mesh extends past the camera path. Detects missing
    /// walls that camera-viability coverage cannot see.
    var enclosureCompleteness: Float = 0
    /// Per-direction captured/missing map matching `EnclosureDirection`.
    var missingEnclosureDirections: [MeshCoverageAnalyzer.EnclosureDirection] = []
    /// Whether the user walked far enough for the enclosure metric to be meaningful.
    var hasEnoughCameraMotion: Bool = false
    /// World-space hole points from the ray-cast detector. Each is a red
    /// marker position rendered in AR so the user can walk toward the gap.
    var localHoles: [MeshCoverageAnalyzer.HoleSample] = []
    /// Feature flag: run on-device coverage review after stop-scan. Disable to restore
    /// the previous "straight to annotation" flow.
    var useInlineCoverageReview: Bool = true
    /// Set to true when returning from coverage review to rescan. Cleared on new scan.
    var isResumingFromCoverage: Bool = false

    // MARK: - UI Flags

    var showHistory = false
    var showInterruptionAlert = false
    var showLowStorageAlert = false
    var showCapReachedAlert = false

    /// True once ARKit reports a `.normal` tracking state after start/resume.
    /// Drives the "Starting camera…" overlay on `ScanningView`.
    var isARSessionReady: Bool = false

    // MARK: - Scan Coaching

    /// Current coaching message shown by `ScanCoachOverlay`.
    var coachingState: ScanCoachingState = .getStarted

    /// Initial "walk slowly" coaching duration before stale-detection kicks in.
    private static let walkSlowlyDuration: TimeInterval = 8.0
    /// Rolling window length for detecting stalled movement.
    private static let coachingStaleWindow: TimeInterval = 3.0
    /// Triangle delta below this within `coachingStaleWindow` counts as stalled.
    private static let coachingTriangleStallDelta = 500
    /// Keyframe delta below this within `coachingStaleWindow` counts as stalled.
    private static let coachingFrameStallDelta = 2
    /// Keyframe threshold for "enough coverage" — must be met together with the
    /// triangle and anchor thresholds below (AND, not OR). Gates `.enoughCoverage`.
    private static let enoughCoverageKeyframes = 500
    /// Triangle threshold for "enough coverage" — AND'd with keyframes + anchors.
    private static let enoughCoverageTriangles = 200_000
    /// Mesh-anchor threshold. Sparse anchors (<8) usually means only one side of
    /// the room has been scanned, so withhold the "you're done" signal.
    private static let enoughCoverageAnchors = 8

    private var coachingCheckpointTime: Date?
    private var coachingCheckpointTriangles: Int = 0
    private var coachingCheckpointFrames: Int = 0

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
        isResumingFromCoverage = false
        localUncoveredFaces = []
        localUncoveredCount = 0
        enclosureCompleteness = 0
        missingEnclosureDirections = []
        hasEnoughCameraMotion = false
        localHoles = []
        coachingState = .getStarted
        coachingCheckpointTime = nil
        coachingCheckpointTriangles = 0
        coachingCheckpointFrames = 0
        state = .scanReady
    }

    /// Begin AR capture. Transitions from scanReady → scanning.
    func startScan() {
        let now = Date()
        scanStartTime = now
        coachingState = .walkSlowly
        coachingCheckpointTime = now
        coachingCheckpointTriangles = 0
        coachingCheckpointFrames = 0
        state = .scanning
    }

    /// Stop capturing. State transition is handled by ContentView (→ reviewingCoverage).
    func stopScan() {
        // State is now set by ContentView.handleStopScan() — do not override here
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
        evaluateCoaching()
    }

    func updateKeyframeCount(_ count: Int) {
        keyframeCount = count
        evaluateCoaching()
    }

    /// Update `coachingState` based on scan time + mesh/keyframe deltas over a rolling window.
    /// Called after every mesh/keyframe update.
    private func evaluateCoaching() {
        guard state == .scanning, let start = scanStartTime else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(start)

        // Stay on "walk slowly" during initial ramp-up.
        if elapsed < Self.walkSlowlyDuration {
            if coachingState != .walkSlowly { coachingState = .walkSlowly }
            coachingCheckpointTime = now
            coachingCheckpointTriangles = meshTriangleCount
            coachingCheckpointFrames = keyframeCount
            return
        }

        // Terminal coaching: enough coverage captured. All three basic thresholds
        // must clear before we tell the user they're done — a single cheap signal
        // (e.g. triangles) can fire from one close-up wall and undersells the task.
        // The inline coverage review handles the final "missing walls" check.
        if keyframeCount >= Self.enoughCoverageKeyframes
            && meshTriangleCount >= Self.enoughCoverageTriangles
            && meshAnchorCount >= Self.enoughCoverageAnchors {
            if coachingState != .enoughCoverage { coachingState = .enoughCoverage }
            return
        }

        // Rolling stale-window check.
        let checkpoint = coachingCheckpointTime ?? start
        let windowElapsed = now.timeIntervalSince(checkpoint)
        guard windowElapsed >= Self.coachingStaleWindow else { return }

        let triDelta = meshTriangleCount - coachingCheckpointTriangles
        let frameDelta = keyframeCount - coachingCheckpointFrames
        let stalled = triDelta < Self.coachingTriangleStallDelta
            && frameDelta < Self.coachingFrameStallDelta

        if stalled {
            if coachingState != .keepMoving { coachingState = .keepMoving }
        } else {
            // Moving again — suppress stall nag back to neutral walk coaching.
            if coachingState == .keepMoving { coachingState = .walkSlowly }
        }

        coachingCheckpointTime = now
        coachingCheckpointTriangles = meshTriangleCount
        coachingCheckpointFrames = keyframeCount
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
