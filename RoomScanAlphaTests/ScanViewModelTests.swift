import XCTest
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan test cases:
/// - 2.8  State transitions (idle <-> scanning)
/// - 3.11 Memory stays bounded (quality gate prevents bad scans)
/// - 4.17 Scan quality validation before export
final class ScanViewModelTests: XCTestCase {

    var viewModel: ScanViewModel!

    override func setUp() {
        super.setUp()
        viewModel = ScanViewModel()
    }

    // MARK: - State transitions (2.8)

    func testInitialStateIsIdle() {
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testStartScanSetsScanning() {
        viewModel.startScan()
        XCTAssertEqual(viewModel.state, .scanning)
    }

    func testStopScanSetsIdle() {
        viewModel.startScan()
        viewModel.stopScan()
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testStartScanResetsCounters() {
        viewModel.updateMeshStats(triangleCount: 5000, anchorCount: 10)
        viewModel.updateKeyframeCount(40)
        viewModel.startScan()

        XCTAssertEqual(viewModel.meshTriangleCount, 0)
        XCTAssertEqual(viewModel.meshAnchorCount, 0)
        XCTAssertEqual(viewModel.keyframeCount, 0)
    }

    func testStartScanResetsExportState() {
        viewModel.exportProgress = "Export complete"
        viewModel.exportError = "some error"
        viewModel.showQualityWarning = true
        viewModel.startScan()

        XCTAssertEqual(viewModel.exportProgress, "")
        XCTAssertNil(viewModel.exportError)
        XCTAssertNil(viewModel.lastExportURL)
        XCTAssertFalse(viewModel.showQualityWarning)
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

    func testScanDurationPositiveAfterStart() {
        viewModel.startScan()
        // scanStartTime is set, so duration should be >= 0
        XCTAssertGreaterThanOrEqual(viewModel.scanDuration, 0)
    }
}
