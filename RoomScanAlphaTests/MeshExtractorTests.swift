import XCTest
import ARKit
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan test case:
/// - 2.5 Classification color coding (wall=blue, floor=green, ceiling=yellow)
final class MeshExtractorTests: XCTestCase {

    // MARK: - Classification colors (2.5)

    func testWallColorIsBlue() {
        let color = MeshExtractor.classificationColor(for: .wall)
        XCTAssertEqual(color, .systemBlue)
    }

    func testFloorColorIsGreen() {
        let color = MeshExtractor.classificationColor(for: .floor)
        XCTAssertEqual(color, .systemGreen)
    }

    func testCeilingColorIsYellow() {
        let color = MeshExtractor.classificationColor(for: .ceiling)
        XCTAssertEqual(color, .systemYellow)
    }

    func testTableColorIsOrange() {
        let color = MeshExtractor.classificationColor(for: .table)
        XCTAssertEqual(color, .systemOrange)
    }

    func testSeatColorIsPurple() {
        let color = MeshExtractor.classificationColor(for: .seat)
        XCTAssertEqual(color, .systemPurple)
    }

    func testWindowColorIsCyan() {
        let color = MeshExtractor.classificationColor(for: .window)
        XCTAssertEqual(color, .systemCyan)
    }

    func testDoorColorIsBrown() {
        let color = MeshExtractor.classificationColor(for: .door)
        XCTAssertEqual(color, .systemBrown)
    }

    func testNoneClassificationIsLightGray() {
        let color = MeshExtractor.classificationColor(for: .none)
        XCTAssertEqual(color, .lightGray)
    }

    func testAllClassificationsReturnNonNilColor() {
        let allCases: [ARMeshClassification] = [.none, .wall, .floor, .ceiling, .table, .seat, .door, .window]
        for classification in allCases {
            let color = MeshExtractor.classificationColor(for: classification)
            XCTAssertNotNil(color, "Classification \(classification) should have a color")
        }
    }
}
