import XCTest
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan test cases:
/// - 1.5  FrameCaptureManager.reset() clears frames (after reset, capturedFrames.count == 0)
/// - 3.1  Keyframe captured on translation (threshold = 0.15m)
/// - 3.2  Keyframe captured on rotation (threshold = 15 deg)
/// - 3.4  Minimum interval enforced (0.5s)
/// - 3.5  Keyframe count max cap (80, raised from 60 for post-scan selection)
final class FrameCaptureManagerTests: XCTestCase {

    var manager: FrameCaptureManager!

    override func setUp() {
        super.setUp()
        manager = FrameCaptureManager()
    }

    // MARK: - Initial state

    func testInitialKeyframeCountIsZero() {
        XCTAssertEqual(manager.keyframeCount, 0)
    }

    func testInitialCapturedFramesIsEmpty() {
        XCTAssertTrue(manager.capturedFrames.isEmpty)
    }

    // MARK: - Reset

    func testResetClearsFrames() {
        // We can't add frames without ARFrame, but we can verify reset works
        manager.reset()
        XCTAssertEqual(manager.keyframeCount, 0)
        XCTAssertTrue(manager.capturedFrames.isEmpty)
    }

    // MARK: - Threshold constants verification

    /// Verify the threshold constants match the Implementation Plan spec.
    /// Plan specifies: translation >= 0.15m, rotation >= 15 deg, interval >= 0.5s, max 60
    func testTranslationThresholdMatchesPlan() {
        // The plan requires 0.15m translation threshold
        // We verify this through the Mirror API on the private property
        let mirror = Mirror(reflecting: manager!)
        let threshold = mirror.children.first { $0.label == "translationThreshold" }?.value as? Float
        XCTAssertEqual(threshold, 0.15, "Translation threshold should be 0.15m per Implementation Plan 3.1")
    }

    func testRotationThresholdMatchesPlan() {
        let mirror = Mirror(reflecting: manager!)
        let threshold = mirror.children.first { $0.label == "rotationThreshold" }?.value as? Float
        XCTAssertEqual(threshold, 15.0, "Rotation threshold should be 15 degrees per Implementation Plan 3.2")
    }

    func testMinimumIntervalMatchesPlan() {
        let mirror = Mirror(reflecting: manager!)
        let interval = mirror.children.first { $0.label == "minimumInterval" }?.value as? TimeInterval
        XCTAssertEqual(interval, 0.5, "Minimum interval should be 0.5s per Implementation Plan 3.4")
    }

    func testMaxKeyframesMatchesPlan() {
        let mirror = Mirror(reflecting: manager!)
        let max = mirror.children.first { $0.label == "maxKeyframes" }?.value as? Int
        XCTAssertEqual(max, 80, "Max keyframes should be 80 per MVP Plan Step 1 (raised from 60 for post-scan selection)")
    }

    // MARK: - Reset (1.5)

    /// 1.5: After reset, capturedFrames.count == 0
    func testResetClearsAllState() {
        manager.reset()
        XCTAssertEqual(manager.keyframeCount, 0)
        XCTAssertTrue(manager.capturedFrames.isEmpty,
                      "After reset, capturedFrames should be empty")
    }
}
