import XCTest
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan Phase 10 test cases:
/// - 10.19 Graceful degradation on low storage (hasEnoughStorage check)
/// - 10.20 No crashes on rapid state changes
final class ErrorRecoveryTests: XCTestCase {

    // MARK: - 10.19 Storage check exists

    func testHasEnoughStorage_returnsBoolean() {
        let vm = ScanViewModel()
        // Just verify the property is accessible and returns a value
        // (actual low-storage simulation requires device manipulation)
        let result = vm.hasEnoughStorage
        XCTAssertTrue(result is Bool)
        // On a dev machine / CI simulator, storage is always > 200MB
        XCTAssertTrue(result, "Simulator should have > 200MB free storage")
    }

    func testLowStorageAlertFlag_initiallyFalse() {
        let vm = ScanViewModel()
        XCTAssertFalse(vm.showLowStorageAlert)
    }

    func testLowStorageAlertFlag_canBeSet() {
        let vm = ScanViewModel()
        vm.showLowStorageAlert = true
        XCTAssertTrue(vm.showLowStorageAlert)
    }

    // MARK: - 10.20 No crashes on rapid state changes

    func testRapidStartStop_nocrash() {
        let vm = ScanViewModel()

        // Rapidly toggle 10 times
        for _ in 0..<10 {
            vm.startScan()
            vm.stopScan()
        }

        // Final state should be consistent
        XCTAssertEqual(vm.state, .idle,
                       "After rapid start/stop, state should be idle")
    }

    func testRapidStartStop_countersResetEachTime() {
        let vm = ScanViewModel()

        for i in 0..<5 {
            vm.updateKeyframeCount(i * 10)
            vm.updateMeshStats(triangleCount: i * 1000, anchorCount: i)
            vm.startScan()
            // After startScan, counters should be zero
            XCTAssertEqual(vm.keyframeCount, 0, "Keyframe count should reset on start (iteration \(i))")
            XCTAssertEqual(vm.meshTriangleCount, 0, "Triangle count should reset on start (iteration \(i))")
            vm.stopScan()
        }
    }

    func testRapidStateTransitions_allStates() {
        let vm = ScanViewModel()

        // Walk through all states rapidly
        vm.state = .idle
        vm.state = .scanning
        vm.state = .exporting
        vm.state = .uploading
        vm.state = .viewingResults
        vm.state = .idle
        vm.state = .scanning
        vm.state = .idle

        XCTAssertEqual(vm.state, .idle, "Should end in idle state")
    }

    func testStartScan_resetsAllUploadState() {
        let vm = ScanViewModel()
        // Set all state as if an upload just completed
        vm.uploadProgress = 1.0
        vm.uploadStatus = "Upload complete"
        vm.uploadError = nil
        vm.lastScanId = "old-scan"
        vm.scanResult = CloudUploader.ScanResult(
            scanId: "old", status: "scan_ready",
            floorAreaSqft: 100, wallAreaSqft: nil, ceilingHeightFt: nil,
            perimeterLinearFt: nil, detectedComponents: nil, scanDimensions: nil
        )
        vm.showQualityWarning = true

        vm.startScan()

        XCTAssertEqual(vm.uploadProgress, 0.0)
        XCTAssertEqual(vm.uploadStatus, "")
        XCTAssertNil(vm.uploadError)
        XCTAssertNil(vm.lastScanId)
        XCTAssertNil(vm.scanResult)
        XCTAssertFalse(vm.showQualityWarning)
        XCTAssertEqual(vm.state, .scanning)
    }

    // MARK: - 10.16 Interruption alert

    func testInterruptionAlertFlag_initiallyFalse() {
        let vm = ScanViewModel()
        XCTAssertFalse(vm.showInterruptionAlert)
    }

    func testInterruptionAlertFlag_canBeToggled() {
        let vm = ScanViewModel()
        vm.showInterruptionAlert = true
        XCTAssertTrue(vm.showInterruptionAlert)
        vm.showInterruptionAlert = false
        XCTAssertFalse(vm.showInterruptionAlert)
    }
}
