import XCTest
@testable import RoomScanAlpha

/// Tests for FrameCaptureManager with HEVC VideoFrameWriter backend.
/// Verifies threshold constants match the updated dense-capture spec.
final class FrameCaptureManagerTests: XCTestCase {

    var manager: FrameCaptureManager!

    override func setUp() {
        super.setUp()
        manager = FrameCaptureManager()
    }

    override func tearDown() {
        manager.reset()
        super.tearDown()
    }

    // MARK: - Initial state

    func testInitialKeyframeCountIsZero() {
        XCTAssertEqual(manager.keyframeCount, 0)
    }

    // MARK: - Reset

    func testResetClearsFrameCount() {
        manager.reset()
        XCTAssertEqual(manager.keyframeCount, 0)
    }

    // MARK: - Threshold constants verification (HEVC dense capture)

    func testMinimumIntervalMatchesPlan() {
        let mirror = Mirror(reflecting: manager!)
        let interval = mirror.children.first { $0.label == "minimumInterval" }?.value as? TimeInterval
        XCTAssertEqual(interval, 0.1, "Minimum interval should be 0.1s for ~10fps continuous HEVC capture")
    }

    func testMaxFramesMatchesPlan() {
        let mirror = Mirror(reflecting: manager!)
        let max = mirror.children.first { $0.label == "maxFrames" }?.value as? Int
        XCTAssertEqual(max, 6000, "Max frames should be 6000 (~10 min at 10fps)")
    }

    // MARK: - VideoFrameWriter integration

    func testVideoWriterIsAccessible() {
        XCTAssertNotNil(manager.videoWriter)
        XCTAssertFalse(manager.videoWriter.hasFailed)
    }

    func testIsAtCapacityFalseInitially() {
        XCTAssertFalse(manager.isAtCapacity)
    }
}
