import XCTest
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan MVP Step 3 test cases:
/// - 3.1  Self-intersection detection (bowtie polygon → validation rejects)
/// - 3.2  Valid polygon accepted (4-corner rectangle, CCW → validation passes, area > 1m²)
/// - 3.3  CW winding auto-corrected to CCW
/// - 3.4  Area bounds enforced (polygon with area < 1m² → rejected)
/// - 3.5  Undo removes last corner (5 corners → undo → 4 corners remain)
/// - 3.6  Skip produces nil annotation (skip → cornerAnnotation == nil)
final class CornerAnnotationViewModelTests: XCTestCase {

    var vm: CornerAnnotationViewModel!

    override func setUp() {
        super.setUp()
        vm = CornerAnnotationViewModel()
    }

    // MARK: - Helper: add corners for a rectangle

    /// Add a 4m x 3m rectangle in XZ plane at Y=2.5 (ceiling height).
    /// CCW winding when viewed from above (positive Y).
    private func addCCWRectangle() {
        vm.addCorner(.init(x: 0, y: 2.5, z: 0))
        vm.addCorner(.init(x: 4, y: 2.5, z: 0))
        vm.addCorner(.init(x: 4, y: 2.5, z: 3))
        vm.addCorner(.init(x: 0, y: 2.5, z: 3))
    }

    /// Add a 4m x 3m rectangle in CW winding.
    private func addCWRectangle() {
        vm.addCorner(.init(x: 0, y: 2.5, z: 0))
        vm.addCorner(.init(x: 0, y: 2.5, z: 3))
        vm.addCorner(.init(x: 4, y: 2.5, z: 3))
        vm.addCorner(.init(x: 4, y: 2.5, z: 0))
    }

    /// Add a bowtie (self-intersecting) polygon.
    private func addBowtiePolygon() {
        vm.addCorner(.init(x: 0, y: 2.5, z: 0))
        vm.addCorner(.init(x: 4, y: 2.5, z: 3))  // crosses
        vm.addCorner(.init(x: 4, y: 2.5, z: 0))
        vm.addCorner(.init(x: 0, y: 2.5, z: 3))  // crosses
    }

    /// Add a tiny polygon (< 1m²).
    private func addTinyPolygon() {
        vm.addCorner(.init(x: 0, y: 2.5, z: 0))
        vm.addCorner(.init(x: 0.5, y: 2.5, z: 0))
        vm.addCorner(.init(x: 0.5, y: 2.5, z: 0.5))
        vm.addCorner(.init(x: 0, y: 2.5, z: 0.5))
    }

    // MARK: - 3.1 Self-intersection detection

    func testBowtiePolygonRejected() {
        addBowtiePolygon()
        vm.closePolygon()

        XCTAssertTrue(vm.hasSelfIntersection,
                      "Bowtie polygon should be detected as self-intersecting")
        XCTAssertFalse(vm.isValid,
                       "Self-intersecting polygon should fail validation")
        XCTAssertFalse(vm.canDone,
                       "Cannot complete with self-intersecting polygon")
    }

    // MARK: - 3.2 Valid polygon accepted

    func testCCWRectangleIsValid() {
        addCCWRectangle()
        vm.closePolygon()
        XCTAssertTrue(vm.isClosed)
        XCTAssertTrue(vm.isValid)
        XCTAssertTrue(vm.canDone)
    }

    func testCCWRectangleArea() {
        addCCWRectangle()
        vm.closePolygon()
        let area = vm.polygonAreaM2
        XCTAssertTrue(abs(area - 12.0) < 0.1, "Area should be ~12m², got \(area)")
    }

    func testCCWRectangleNoSelfIntersection() {
        addCCWRectangle()
        vm.closePolygon()
        XCTAssertFalse(vm.hasSelfIntersection)
    }

    // MARK: - 3.3 CW winding auto-corrected to CCW

    func testCWWindingCorrectedToCCW() {
        addCWRectangle()
        vm.closePolygon()

        XCTAssertFalse(vm.isCCW, "CW rectangle should not be CCW")

        let normalized = vm.cornersNormalizedCCW
        // After normalization, the first corner should be different
        // (reversed order). Check that the area sign is now positive.
        var signedArea: Float = 0
        for i in 0..<normalized.count {
            let j = (i + 1) % normalized.count
            signedArea += normalized[i].x * normalized[j].z - normalized[j].x * normalized[i].z
        }
        signedArea /= 2
        XCTAssertGreaterThan(signedArea, 0,
                             "Normalized corners should have positive (CCW) signed area")
    }

    func testCCWWindingPreserved() {
        addCCWRectangle()
        XCTAssertTrue(vm.isCCW, "CCW rectangle should be detected as CCW")

        let original = vm.corners.map { $0.x }
        let normalized = vm.cornersNormalizedCCW.map { $0.x }
        XCTAssertEqual(original, normalized,
                       "CCW corners should not be reversed")
    }

    // MARK: - 3.4 Area bounds enforced

    func testTinyPolygonRejected() {
        addTinyPolygon()
        vm.closePolygon()

        let area = vm.polygonAreaM2
        XCTAssertLessThan(area, CornerAnnotationViewModel.minAreaM2,
                          "Tiny polygon area (\(area)) should be < 1m²")
        XCTAssertFalse(vm.isValid,
                       "Polygon with area < 1m² should fail validation")
    }

    func testAreaBoundsConstants() {
        XCTAssertEqual(CornerAnnotationViewModel.minAreaM2, 1.0)
        XCTAssertEqual(CornerAnnotationViewModel.maxAreaM2, 500.0)
    }

    // MARK: - 3.5 Undo removes last corner

    func testUndoRemovesLastCorner() {
        vm.addCorner(.init(x: 0, y: 2.5, z: 0))
        vm.addCorner(.init(x: 1, y: 2.5, z: 0))
        vm.addCorner(.init(x: 1, y: 2.5, z: 1))
        vm.addCorner(.init(x: 0, y: 2.5, z: 1))
        vm.addCorner(.init(x: 0.5, y: 2.5, z: 2))
        XCTAssertEqual(vm.cornerCount, 5)

        vm.undoLastCorner()

        XCTAssertEqual(vm.cornerCount, 4)
        // Last corner should now be (0, 2.5, 1)
        XCTAssertEqual(Double(vm.corners.last?.z ?? 0), 1.0, accuracy: 0.01)
    }

    func testUndoOnEmptyDoesNothing() {
        vm.undoLastCorner()
        XCTAssertEqual(vm.cornerCount, 0)
    }

    func testUndoDisabledAfterClose() {
        addCCWRectangle()
        vm.closePolygon()
        let countBefore = vm.cornerCount

        vm.undoLastCorner()

        XCTAssertEqual(vm.cornerCount, countBefore,
                       "Undo should be disabled after polygon is closed")
    }

    // MARK: - 3.6 Skip produces nil annotation

    func testSkipProducesNilAnnotation() {
        // No corners placed, polygon not closed
        XCTAssertNil(vm.cornerAnnotation,
                     "Skip (no annotation) should produce nil cornerAnnotation")
    }

    func testSkipWithUnclosedCornersProducesNil() {
        vm.addCorner(.init(x: 0, y: 2.5, z: 0))
        vm.addCorner(.init(x: 4, y: 2.5, z: 0))
        // Not closed
        XCTAssertNil(vm.cornerAnnotation,
                     "Unclosed polygon should produce nil cornerAnnotation")
    }

    // MARK: - Export annotation

    func testValidAnnotationExport() {
        addCCWRectangle()
        vm.closePolygon()

        let annotation = vm.cornerAnnotation
        XCTAssertNotNil(annotation)
        XCTAssertEqual(annotation?.corners_xz.count, 4)
        XCTAssertEqual(annotation?.corners_y.count, 4)
        XCTAssertEqual(annotation?.annotation_method, "ar_crosshair_snap")
        XCTAssertFalse(annotation?.timestamp.isEmpty ?? true)
    }

    func testExportedCornersAreCCW() {
        addCWRectangle()
        vm.closePolygon()

        let annotation = vm.cornerAnnotation
        XCTAssertNotNil(annotation)

        // Verify CCW by computing signed area from exported corners_xz
        let xz = annotation!.corners_xz
        var signedArea: Float = 0
        for i in 0..<xz.count {
            let j = (i + 1) % xz.count
            signedArea += xz[i][0] * xz[j][1] - xz[j][0] * xz[i][1]
        }
        signedArea /= 2
        XCTAssertGreaterThan(signedArea, 0,
                             "Exported corners should always be CCW (positive signed area)")
    }

    // MARK: - Geometry helpers

    func testSegmentsIntersect_crossing() {
        let result = CornerAnnotationViewModel.segmentsIntersect(
            SIMD2(0, 0), SIMD2(1, 1),
            SIMD2(0, 1), SIMD2(1, 0)
        )
        XCTAssertTrue(result, "X-shaped segments should intersect")
    }

    func testSegmentsIntersect_parallel() {
        let result = CornerAnnotationViewModel.segmentsIntersect(
            SIMD2(0, 0), SIMD2(1, 0),
            SIMD2(0, 1), SIMD2(1, 1)
        )
        XCTAssertFalse(result, "Parallel segments should not intersect")
    }

    func testSegmentsIntersect_noOverlap() {
        let result = CornerAnnotationViewModel.segmentsIntersect(
            SIMD2(0, 0), SIMD2(1, 0),
            SIMD2(2, 0), SIMD2(3, 0)
        )
        XCTAssertFalse(result, "Non-overlapping collinear segments should not intersect")
    }

    func testFitPlane_horizontalPlane() {
        let points: [SIMD3<Float>] = [
            SIMD3(0, 5, 0), SIMD3(1, 5, 0), SIMD3(0, 5, 1),
            SIMD3(1, 5, 1), SIMD3(0.5, 5, 0.5)
        ]
        let result = CornerAnnotationViewModel.fitPlane(points: points)
        XCTAssertNotNil(result)

        // Normal should be approximately (0, ±1, 0)
        let normal = result!.normal
        XCTAssertEqual(abs(normal.y), 1.0, accuracy: 0.01,
                       "Horizontal plane normal should point along Y axis")
    }

    // MARK: - Reset

    func testResetClearsAll() {
        addCCWRectangle()
        vm.closePolygon()
        vm.reset()

        XCTAssertEqual(vm.cornerCount, 0)
        XCTAssertFalse(vm.isClosed)
        XCTAssertNil(vm.cornerAnnotation)
    }

    // MARK: - State guards

    func testCannotAddCornerAfterClose() {
        addCCWRectangle()
        vm.closePolygon()
        vm.addCorner(.init(x: 5, y: 2.5, z: 5))

        XCTAssertEqual(vm.cornerCount, 4,
                       "Should not be able to add corners after closing")
    }

    func testCannotCloseWithLessThan3Corners() {
        vm.addCorner(.init(x: 0, y: 2.5, z: 0))
        vm.addCorner(.init(x: 1, y: 2.5, z: 0))
        XCTAssertFalse(vm.canClose)

        vm.closePolygon()
        XCTAssertFalse(vm.isClosed)
    }

    func testCanCloseWith3Corners() {
        vm.addCorner(.init(x: 0, y: 2.5, z: 0))
        vm.addCorner(.init(x: 4, y: 2.5, z: 0))
        vm.addCorner(.init(x: 4, y: 2.5, z: 3))
        XCTAssertTrue(vm.canClose)
    }
}
