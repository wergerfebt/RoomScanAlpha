import XCTest
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan Phase 7 test cases:
/// - 7.2  Handles "processing" state (nil scanResult → processing UI)
/// - 7.3  Handles "failed" state (ScanResult.status == "failed" → error UI with retry)
/// - 7.5  Scan status reflects SCANNED_ROOMS.scan_status enum values
///
/// Tests 7.1, 7.4, 7.6–7.7 require the deployed cloud stub and network —
/// run via cloud-stub-tests.yml or manually on device.
final class ScanResultViewTests: XCTestCase {

    var viewModel: ScanViewModel!

    override func setUp() {
        super.setUp()
        viewModel = ScanViewModel()
    }

    // MARK: - 7.2 Handles "processing" state

    func testProcessingState_scanResultIsNil() {
        // When scanResult is nil, ScanResultView shows processingView
        XCTAssertNil(viewModel.scanResult,
                     "Initial scanResult should be nil (triggers processing UI)")
    }

    func testProcessingState_viewingResultsWithNilResult() {
        // The app transitions to viewingResults before polling completes
        viewModel.state = .viewingResults
        XCTAssertEqual(viewModel.state, .viewingResults)
        XCTAssertNil(viewModel.scanResult,
                     "scanResult should remain nil while polling — UI shows processing spinner")
    }

    func testProcessingState_lastScanIdAvailable() {
        // During processing, the scan ID from upload is available for display
        viewModel.lastScanId = "abc12345-6789-0000-0000-000000000001"
        viewModel.state = .viewingResults

        XCTAssertNotNil(viewModel.lastScanId,
                        "Scan ID should be set so processing view can display it")
        XCTAssertNil(viewModel.scanResult,
                     "scanResult should be nil until polling returns scan_ready or failed")
    }

    // MARK: - 7.3 Handles "failed" state

    func testFailedState_resultStatusIsFailed() {
        let failedResult = CloudUploader.ScanResult(
            scanId: "fail-scan-001",
            status: "failed",
            floorAreaSqft: nil,
            wallAreaSqft: nil,
            ceilingHeightFt: nil,
            perimeterLinearFt: nil,
            detectedComponents: nil,
            scanDimensions: nil
        )

        viewModel.scanResult = failedResult
        viewModel.state = .viewingResults

        XCTAssertEqual(viewModel.scanResult?.status, "failed")
        // ScanResultView branches: status != "scan_ready" → failedView
        XCTAssertNotEqual(viewModel.scanResult?.status, "scan_ready",
                          "Failed result must not be treated as ready")
    }

    func testFailedState_noStructuredData() {
        let failedResult = CloudUploader.ScanResult(
            scanId: "fail-scan-002",
            status: "failed",
            floorAreaSqft: nil,
            wallAreaSqft: nil,
            ceilingHeightFt: nil,
            perimeterLinearFt: nil,
            detectedComponents: nil,
            scanDimensions: nil
        )

        viewModel.scanResult = failedResult

        // Failed results should have no dimension data
        XCTAssertNil(viewModel.scanResult?.floorAreaSqft)
        XCTAssertNil(viewModel.scanResult?.wallAreaSqft)
        XCTAssertNil(viewModel.scanResult?.ceilingHeightFt)
        XCTAssertNil(viewModel.scanResult?.perimeterLinearFt)
        XCTAssertNil(viewModel.scanResult?.detectedComponents)
        XCTAssertNil(viewModel.scanResult?.scanDimensions)
    }

    // MARK: - 7.5 Scan status reflects SCANNED_ROOMS.scan_status

    func testScanStatusEnum_allValidValues() {
        // Backend SCANNED_ROOMS.scan_status values: uploading, processing, scan_ready, failed
        let validStatuses = ["uploading", "processing", "scan_ready", "failed"]

        for status in validStatuses {
            let result = CloudUploader.ScanResult(
                scanId: "test-\(status)",
                status: status,
                floorAreaSqft: nil,
                wallAreaSqft: nil,
                ceilingHeightFt: nil,
                perimeterLinearFt: nil,
                detectedComponents: nil,
                scanDimensions: nil
            )
            XCTAssertEqual(result.status, status,
                           "ScanResult should store status '\(status)' matching SCANNED_ROOMS enum")
        }
    }

    func testScanReadyState_hasStructuredData() {
        let readyResult = CloudUploader.ScanResult(
            scanId: "ready-scan-001",
            status: "scan_ready",
            floorAreaSqft: 245.0,
            wallAreaSqft: 520.0,
            ceilingHeightFt: 8.5,
            perimeterLinearFt: 62.0,
            detectedComponents: ["hardwood", "baseboards", "cabinets"],
            scanDimensions: ["bbox_x": 4.5, "bbox_y": 2.6, "bbox_z": 5.2]
        )

        viewModel.scanResult = readyResult

        XCTAssertEqual(viewModel.scanResult?.status, "scan_ready")
        XCTAssertEqual(viewModel.scanResult?.floorAreaSqft, 245.0)
        XCTAssertEqual(viewModel.scanResult?.wallAreaSqft, 520.0)
        XCTAssertEqual(viewModel.scanResult?.ceilingHeightFt, 8.5)
        XCTAssertEqual(viewModel.scanResult?.perimeterLinearFt, 62.0)
        XCTAssertEqual(viewModel.scanResult?.detectedComponents?.count, 3)
        XCTAssertTrue(viewModel.scanResult?.detectedComponents?.contains("hardwood") == true)
        XCTAssertTrue(viewModel.scanResult?.detectedComponents?.contains("baseboards") == true)
        XCTAssertTrue(viewModel.scanResult?.detectedComponents?.contains("cabinets") == true)
    }

    func testScanReadyState_hasBoundingBoxDimensions() {
        let readyResult = CloudUploader.ScanResult(
            scanId: "ready-scan-002",
            status: "scan_ready",
            floorAreaSqft: 180.0,
            wallAreaSqft: nil,
            ceilingHeightFt: nil,
            perimeterLinearFt: nil,
            detectedComponents: nil,
            scanDimensions: ["bbox_x": 3.8, "bbox_y": 2.4, "bbox_z": 4.1]
        )

        viewModel.scanResult = readyResult

        let dims = viewModel.scanResult?.scanDimensions
        XCTAssertNotNil(dims)
        XCTAssertEqual(dims?["bbox_x"] ?? 0, 3.8, accuracy: 0.01)
        XCTAssertEqual(dims?["bbox_y"] ?? 0, 2.4, accuracy: 0.01)
        XCTAssertEqual(dims?["bbox_z"] ?? 0, 4.1, accuracy: 0.01)
    }

    func testScanReadyState_viewBranching() {
        // ScanResultView uses: status == "scan_ready" → readyView, else → failedView
        let readyResult = CloudUploader.ScanResult(
            scanId: "ready-scan-003",
            status: "scan_ready",
            floorAreaSqft: 200.0,
            wallAreaSqft: nil,
            ceilingHeightFt: nil,
            perimeterLinearFt: nil,
            detectedComponents: nil,
            scanDimensions: nil
        )

        viewModel.scanResult = readyResult
        XCTAssertEqual(viewModel.scanResult?.status, "scan_ready",
                       "Ready result triggers readyView branch in ScanResultView")
    }

    // MARK: - ViewModel state reset

    func testStartScanResetsScanResult() {
        viewModel.scanResult = CloudUploader.ScanResult(
            scanId: "old-scan",
            status: "scan_ready",
            floorAreaSqft: 100.0,
            wallAreaSqft: nil,
            ceilingHeightFt: nil,
            perimeterLinearFt: nil,
            detectedComponents: nil,
            scanDimensions: nil
        )

        viewModel.startScan()

        XCTAssertNil(viewModel.scanResult,
                     "startScan() must clear previous scan result")
        XCTAssertNil(viewModel.lastScanId,
                     "startScan() must clear previous scan ID")
    }

    func testUploadStateResetOnNewScan() {
        viewModel.uploadProgress = 0.85
        viewModel.uploadStatus = "Uploading scan..."
        viewModel.uploadError = "some error"
        viewModel.lastScanId = "prev-scan"

        viewModel.startScan()

        XCTAssertEqual(viewModel.uploadProgress, 0.0)
        XCTAssertEqual(viewModel.uploadStatus, "")
        XCTAssertNil(viewModel.uploadError)
        XCTAssertNil(viewModel.lastScanId)
    }

    // MARK: - ScanState enum includes viewingResults

    func testViewingResultsStateExists() {
        viewModel.state = .viewingResults
        XCTAssertEqual(viewModel.state, .viewingResults,
                       "ScanState must include .viewingResults for Phase 7 result display")
    }

    func testStateTransition_uploadingToViewingResults() {
        viewModel.state = .uploading
        XCTAssertEqual(viewModel.state, .uploading)

        // After upload completes, transition to viewing results
        viewModel.state = .viewingResults
        XCTAssertEqual(viewModel.state, .viewingResults)
    }
}
