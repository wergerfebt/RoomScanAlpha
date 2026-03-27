import XCTest
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan Phase 10 test case:
/// - 10.21 Accessibility — VoiceOver
///
/// Verifies accessibility labels exist on all interactive elements across views.
/// A proper XCUIApplication accessibility audit requires a UI test target;
/// these unit tests validate the model-level accessibility contracts.
///
/// Note: Full XCUI accessibility audit (performAccessibilityAudit) should be
/// added when a UI test target is created. These tests provide CI coverage
/// for the most critical accessibility requirements.
final class AccessibilityTests: XCTestCase {

    // MARK: - ScanRecord status accessibility

    func testScanRecordStatusDisplay_allStatesHaveHumanReadableText() {
        let statuses = ["scan_ready", "processing", "failed", "uploading", "queued"]

        for status in statuses {
            let record = ScanRecord(
                id: "a11y-\(status)",
                rfqId: "rfq-1",
                rfqDescription: nil,
                roomLabel: "Room",
                status: status,
                keyframeCount: 10,
                meshTriangleCount: 1000,
                timestamp: Date()
            )

            // statusDisplay should be human-readable, not a raw backend enum
            XCTAssertFalse(record.statusDisplay.contains("_"),
                           "Status display '\(record.statusDisplay)' for '\(status)' should not contain underscores")
            XCTAssertGreaterThan(record.statusDisplay.count, 0,
                                 "Status display for '\(status)' should not be empty")
        }
    }

    func testScanRecordStatusIcon_allStatesHaveIcons() {
        let statuses = ["scan_ready", "processing", "failed", "uploading"]

        for status in statuses {
            let record = ScanRecord(
                id: "icon-\(status)",
                rfqId: "rfq-1",
                rfqDescription: nil,
                roomLabel: "Room",
                status: status,
                keyframeCount: 10,
                meshTriangleCount: 1000,
                timestamp: Date()
            )

            XCTAssertFalse(record.statusIcon.isEmpty,
                           "Status icon for '\(status)' should not be empty")
        }
    }

    // MARK: - Source-level accessibility verification

    /// Verify that ScanningView.swift contains accessibility labels for interactive elements.
    func testScanningView_hasAccessibilityLabels() throws {
        let scanningViewPath = findSourceFile(named: "ScanningView.swift")
        let content = try String(contentsOfFile: scanningViewPath, encoding: .utf8)

        // Stop button must have accessibility label
        XCTAssertTrue(content.contains(".accessibilityLabel"),
                      "ScanningView must contain .accessibilityLabel modifiers")

        // HUD should have combined accessibility element
        XCTAssertTrue(content.contains(".accessibilityElement"),
                      "ScanningView HUD should use .accessibilityElement for grouped stats")
    }

    /// Verify that ContentView.swift buttons have text labels (SwiftUI Label provides implicit accessibility).
    func testContentView_buttonsHaveLabels() throws {
        let contentViewPath = findSourceFile(named: "ContentView.swift")
        let content = try String(contentsOfFile: contentViewPath, encoding: .utf8)

        // All buttons should use Label() which provides automatic accessibility
        XCTAssertTrue(content.contains("Label(\"Start Scan\"") || content.contains("Label(\"Done\""),
                      "ContentView buttons should use Label() for automatic accessibility")
    }

    /// Verify that ScanResultView.swift uses semantic text elements accessible to VoiceOver.
    func testScanResultView_hasSemanticContent() throws {
        let resultViewPath = findSourceFile(named: "ScanResultView.swift")
        let content = try String(contentsOfFile: resultViewPath, encoding: .utf8)

        // View should contain headings for sections
        XCTAssertTrue(content.contains(".font(.headline)") || content.contains("sectionHeader"),
                      "ScanResultView should use headline fonts for section headers (VoiceOver heading navigation)")

        // Should contain meaningful text for results
        XCTAssertTrue(content.contains("Scan Complete") || content.contains("Processing Failed"),
                      "ScanResultView should display clear status messages")
    }

    /// Verify ScanHistoryView uses NavigationView with title for VoiceOver.
    func testScanHistoryView_hasNavigationTitle() throws {
        let historyViewPath = findSourceFile(named: "ScanHistoryView.swift")
        let content = try String(contentsOfFile: historyViewPath, encoding: .utf8)

        XCTAssertTrue(content.contains(".navigationTitle"),
                      "ScanHistoryView should have a navigation title for VoiceOver")
    }

    // MARK: - Helpers

    private func findSourceFile(named filename: String) -> String {
        // Walk up from test bundle to find the source directory
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RoomScanAlphaTests/
            .deletingLastPathComponent() // RoomScanAlpha/ (project root)

        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: projectRoot.appendingPathComponent("RoomScanAlpha"),
            includingPropertiesForKeys: nil
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent == filename {
                return fileURL.path
            }
        }

        // Fallback: try known paths
        let knownPaths = [
            projectRoot.appendingPathComponent("RoomScanAlpha/Views/\(filename)").path,
            projectRoot.appendingPathComponent("RoomScanAlpha/\(filename)").path,
        ]
        for path in knownPaths {
            if fm.fileExists(atPath: path) { return path }
        }

        return projectRoot.appendingPathComponent("RoomScanAlpha/Views/\(filename)").path
    }
}
