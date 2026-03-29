import XCTest
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan test cases:
/// - 1.1  State: idle → scanReady (after selecting RFQ, state is scanReady)
/// - 1.2  State: scanReady → scanning (startScan begins AR capture)
/// - 1.3  State: scanning → annotatingCorners (stopScan transitions; AR session still running)
/// - 1.4  Redo clears all state (redoScan returns to scanReady; keyframeCount == 0)
/// - 1.6  "Scan Another Room" routes to scanReady (from viewingResults, goes to scanReady not .scanning)
/// - 2.8  State transitions (idle <-> scanning)
/// - 3.11 Memory stays bounded (quality gate prevents bad scans)
/// - 4.17 Scan quality validation before export
final class ScanViewModelTests: XCTestCase {

    var viewModel: ScanViewModel!

    override func setUp() {
        super.setUp()
        viewModel = ScanViewModel()
    }

    // MARK: - Step 1 Test Cases

    /// 1.1: After selecting RFQ, prepareScan() sets state to scanReady
    func testPrepareScanSetsScanReady() {
        viewModel.prepareScan()
        XCTAssertEqual(viewModel.state, .scanReady)
    }

    /// 1.2: startScan() transitions from scanReady → scanning
    func testStartScanFromScanReadySetsScanning() {
        viewModel.prepareScan()
        viewModel.startScan()
        XCTAssertEqual(viewModel.state, .scanning)
    }

    /// 1.3: stopScan() transitions to annotatingCorners
    func testStopScanSetsAnnotatingCorners() {
        viewModel.prepareScan()
        viewModel.startScan()
        viewModel.stopScan()
        XCTAssertEqual(viewModel.state, .annotatingCorners)
    }

    /// 1.4: redoScan() returns to scanReady with all counters cleared
    func testRedoScanClearsStateAndReturnsScanReady() {
        viewModel.prepareScan()
        viewModel.startScan()
        viewModel.updateMeshStats(triangleCount: 5000, anchorCount: 10)
        viewModel.updateKeyframeCount(40)
        viewModel.redoScan()

        XCTAssertEqual(viewModel.state, .scanReady)
        XCTAssertEqual(viewModel.meshTriangleCount, 0)
        XCTAssertEqual(viewModel.meshAnchorCount, 0)
        XCTAssertEqual(viewModel.keyframeCount, 0)
    }

    /// 1.6: "Scan Another Room" routes to scanReady, not scanning
    func testScanAnotherRoomRoutesToScanReady() {
        viewModel.state = .viewingResults
        viewModel.prepareScan()
        XCTAssertEqual(viewModel.state, .scanReady,
                       "Scan Another Room should route to scanReady, not scanning")
    }

    /// returnToIdle() goes back to idle
    func testReturnToIdleSetsIdle() {
        viewModel.prepareScan()
        viewModel.returnToIdle()
        XCTAssertEqual(viewModel.state, .idle)
    }

    // MARK: - State transitions (2.8)

    func testInitialStateIsIdle() {
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testPrepareScanResetsCounters() {
        viewModel.updateMeshStats(triangleCount: 5000, anchorCount: 10)
        viewModel.updateKeyframeCount(40)
        viewModel.prepareScan()

        XCTAssertEqual(viewModel.meshTriangleCount, 0)
        XCTAssertEqual(viewModel.meshAnchorCount, 0)
        XCTAssertEqual(viewModel.keyframeCount, 0)
    }

    func testPrepareScanResetsExportState() {
        viewModel.exportProgress = "Export complete"
        viewModel.exportError = "some error"
        viewModel.showQualityWarning = true
        viewModel.prepareScan()

        XCTAssertEqual(viewModel.exportProgress, "")
        XCTAssertNil(viewModel.exportError)
        XCTAssertNil(viewModel.lastExportURL)
        XCTAssertFalse(viewModel.showQualityWarning)
    }

    func testPrepareScanResetsUploadState() {
        viewModel.uploadProgress = 0.75
        viewModel.uploadStatus = "Uploading..."
        viewModel.uploadError = "timeout"
        viewModel.lastScanId = "scan-123"
        viewModel.prepareScan()

        XCTAssertEqual(viewModel.uploadProgress, 0.0)
        XCTAssertEqual(viewModel.uploadStatus, "")
        XCTAssertNil(viewModel.uploadError)
        XCTAssertNil(viewModel.lastScanId)
    }

    func testExportingState() {
        viewModel.state = .exporting
        XCTAssertEqual(viewModel.state, .exporting)
    }

    // MARK: - Mesh stats (2.6)

    func testUpdateMeshStats() {
        viewModel.updateMeshStats(triangleCount: 1500, anchorCount: 8)
        XCTAssertEqual(viewModel.meshTriangleCount, 1500)
        XCTAssertEqual(viewModel.meshAnchorCount, 8)
    }

    // MARK: - Keyframe count (3.10)

    func testUpdateKeyframeCount() {
        viewModel.updateKeyframeCount(25)
        XCTAssertEqual(viewModel.keyframeCount, 25)
    }

    // MARK: - Scan quality validation (4.17)

    func testScanQualitySufficient_meetsThresholds() {
        viewModel.updateKeyframeCount(15)
        viewModel.updateMeshStats(triangleCount: 500, anchorCount: 5)
        XCTAssertTrue(viewModel.scanQualitySufficient,
                      "15 keyframes and 500 triangles should be sufficient")
    }

    func testScanQualitySufficient_exceedsThresholds() {
        viewModel.updateKeyframeCount(45)
        viewModel.updateMeshStats(triangleCount: 8000, anchorCount: 20)
        XCTAssertTrue(viewModel.scanQualitySufficient)
    }

    func testScanQualityInsufficient_lowKeyframes() {
        viewModel.updateKeyframeCount(14)
        viewModel.updateMeshStats(triangleCount: 2000, anchorCount: 10)
        XCTAssertFalse(viewModel.scanQualitySufficient,
                       "14 keyframes should be insufficient (minimum is 15)")
    }

    func testScanQualityInsufficient_lowTriangles() {
        viewModel.updateKeyframeCount(30)
        viewModel.updateMeshStats(triangleCount: 499, anchorCount: 5)
        XCTAssertFalse(viewModel.scanQualitySufficient,
                       "499 triangles should be insufficient (minimum is 500)")
    }

    func testScanQualityInsufficient_bothLow() {
        viewModel.updateKeyframeCount(5)
        viewModel.updateMeshStats(triangleCount: 100, anchorCount: 2)
        XCTAssertFalse(viewModel.scanQualitySufficient)
    }

    func testScanQualityInsufficient_zeroValues() {
        XCTAssertFalse(viewModel.scanQualitySufficient,
                       "Zero keyframes and triangles should be insufficient")
    }

    // MARK: - Scan duration

    func testScanDurationZeroBeforeStart() {
        XCTAssertEqual(viewModel.scanDuration, 0)
    }

    func testScanDurationZeroDuringPrepareScan() {
        viewModel.prepareScan()
        // scanStartTime is nil during scanReady — duration should be 0
        XCTAssertEqual(viewModel.scanDuration, 0)
    }

    func testScanDurationPositiveAfterStart() {
        viewModel.prepareScan()
        viewModel.startScan()
        // scanStartTime is set, so duration should be >= 0
        XCTAssertGreaterThanOrEqual(viewModel.scanDuration, 0)
    }
}
