import XCTest
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan Phase 10 test cases:
/// - 10.12 Scan history persists (save/load via ScanHistoryStore)
/// - 10.13 Scan history shows correct status (statusDisplay mapping)
/// - 10.14 Scan history shows RFQ grouping (groupedByRFQ)
final class ScanHistoryTests: XCTestCase {

    private let store = ScanHistoryStore.shared
    private let historyKey = "scanHistory"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: historyKey)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRecord(
        id: String = UUID().uuidString,
        rfqId: String = "rfq-1",
        rfqDescription: String? = "Test Project",
        roomLabel: String = "Kitchen",
        status: String = "scan_ready",
        keyframeCount: Int = 30,
        meshTriangleCount: Int = 5000,
        timestamp: Date = Date()
    ) -> ScanRecord {
        ScanRecord(
            id: id,
            rfqId: rfqId,
            rfqDescription: rfqDescription,
            roomLabel: roomLabel,
            status: status,
            keyframeCount: keyframeCount,
            meshTriangleCount: meshTriangleCount,
            timestamp: timestamp
        )
    }

    // MARK: - 10.12 Scan history persists

    func testSaveAndLoadSingleRecord() {
        let record = makeRecord(id: "scan-001")
        store.save(record)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "scan-001")
    }

    func testSaveMultipleRecords_orderedMostRecentFirst() {
        let r1 = makeRecord(id: "scan-1", timestamp: Date(timeIntervalSince1970: 1000))
        let r2 = makeRecord(id: "scan-2", timestamp: Date(timeIntervalSince1970: 2000))
        let r3 = makeRecord(id: "scan-3", timestamp: Date(timeIntervalSince1970: 3000))

        store.save(r1)
        store.save(r2)
        store.save(r3)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 3)
        // Most recent first (inserted at index 0)
        XCTAssertEqual(loaded[0].id, "scan-3")
    }

    func testUpdateExistingRecord() {
        let original = makeRecord(id: "scan-update", status: "processing")
        store.save(original)

        let updated = makeRecord(id: "scan-update", status: "scan_ready")
        store.save(updated)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1, "Should update in place, not duplicate")
        XCTAssertEqual(loaded.first?.status, "scan_ready")
    }

    func testHistoryCappedAt100() {
        for i in 0..<110 {
            store.save(makeRecord(id: "scan-\(i)"))
        }

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 100, "History should cap at 100 records")
    }

    func testHistorySurvivesReload() {
        store.save(makeRecord(id: "persist-test", roomLabel: "Living Room"))

        // Simulate "reload" by reading from UserDefaults directly
        let data = UserDefaults.standard.data(forKey: historyKey)
        XCTAssertNotNil(data, "History data should be persisted to UserDefaults")

        let decoded = try? JSONDecoder().decode([ScanRecord].self, from: data!)
        XCTAssertEqual(decoded?.first?.id, "persist-test")
        XCTAssertEqual(decoded?.first?.roomLabel, "Living Room")
    }

    // MARK: - 10.13 Scan history shows correct status

    func testStatusDisplay_scanReady() {
        let record = makeRecord(status: "scan_ready")
        XCTAssertEqual(record.statusDisplay, "Complete")
    }

    func testStatusDisplay_processing() {
        let record = makeRecord(status: "processing")
        XCTAssertEqual(record.statusDisplay, "Processing")
    }

    func testStatusDisplay_failed() {
        let record = makeRecord(status: "failed")
        XCTAssertEqual(record.statusDisplay, "Failed")
    }

    func testStatusDisplay_uploading() {
        let record = makeRecord(status: "uploading")
        XCTAssertEqual(record.statusDisplay, "Uploading")
    }

    func testStatusDisplay_unknownFallback() {
        let record = makeRecord(status: "queued")
        XCTAssertEqual(record.statusDisplay, "Queued", "Unknown status should be capitalized")
    }

    func testStatusIcon_scanReady() {
        let record = makeRecord(status: "scan_ready")
        XCTAssertEqual(record.statusIcon, "checkmark.circle.fill")
    }

    func testStatusIcon_processing() {
        let record = makeRecord(status: "processing")
        XCTAssertEqual(record.statusIcon, "clock.fill")
    }

    func testStatusIcon_failed() {
        let record = makeRecord(status: "failed")
        XCTAssertEqual(record.statusIcon, "xmark.circle.fill")
    }

    // MARK: - 10.14 Scan history shows RFQ grouping

    func testGroupedByRFQ_singleGroup() {
        store.save(makeRecord(id: "s1", rfqId: "rfq-A", roomLabel: "Kitchen"))
        store.save(makeRecord(id: "s2", rfqId: "rfq-A", roomLabel: "Bathroom"))
        store.save(makeRecord(id: "s3", rfqId: "rfq-A", roomLabel: "Bedroom"))

        let groups = store.groupedByRFQ()
        XCTAssertEqual(groups.count, 1, "All scans share rfq-A")
        XCTAssertEqual(groups[0].rfqId, "rfq-A")
        XCTAssertEqual(groups[0].scans.count, 3)
    }

    func testGroupedByRFQ_multipleGroups() {
        store.save(makeRecord(id: "s1", rfqId: "rfq-A", rfqDescription: "123 Main St"))
        store.save(makeRecord(id: "s2", rfqId: "rfq-B", rfqDescription: "456 Oak Ave"))
        store.save(makeRecord(id: "s3", rfqId: "rfq-A", rfqDescription: "123 Main St"))

        let groups = store.groupedByRFQ()
        XCTAssertEqual(groups.count, 2)

        let rfqAGroup = groups.first(where: { $0.rfqId == "rfq-A" })
        let rfqBGroup = groups.first(where: { $0.rfqId == "rfq-B" })

        XCTAssertEqual(rfqAGroup?.scans.count, 2)
        XCTAssertEqual(rfqBGroup?.scans.count, 1)
        XCTAssertEqual(rfqAGroup?.rfqDescription, "123 Main St")
        XCTAssertEqual(rfqBGroup?.rfqDescription, "456 Oak Ave")
    }

    func testGroupedByRFQ_emptyHistory() {
        let groups = store.groupedByRFQ()
        XCTAssertTrue(groups.isEmpty)
    }

    func testGroupedByRFQ_preservesRoomLabels() {
        store.save(makeRecord(id: "s1", rfqId: "rfq-X", roomLabel: "Kitchen"))
        store.save(makeRecord(id: "s2", rfqId: "rfq-X", roomLabel: "Master Bedroom"))

        let groups = store.groupedByRFQ()
        let roomLabels = Set(groups[0].scans.map(\.roomLabel))
        XCTAssertTrue(roomLabels.contains("Kitchen"))
        XCTAssertTrue(roomLabels.contains("Master Bedroom"))
    }

    // MARK: - Step 5: Delete scan (5.3 local)

    func testDeleteRemovesRecordFromStore() {
        store.save(makeRecord(id: "del-1", rfqId: "rfq-A"))
        store.save(makeRecord(id: "del-2", rfqId: "rfq-A"))
        store.save(makeRecord(id: "del-3", rfqId: "rfq-B"))
        XCTAssertEqual(store.loadAll().count, 3)

        store.delete(scanId: "del-2")

        let remaining = store.loadAll()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertFalse(remaining.contains(where: { $0.id == "del-2" }),
                       "Deleted record should be removed")
        XCTAssertTrue(remaining.contains(where: { $0.id == "del-1" }))
        XCTAssertTrue(remaining.contains(where: { $0.id == "del-3" }))
    }

    func testDeleteNonexistentIdIsNoOp() {
        store.save(makeRecord(id: "keep-1"))
        store.delete(scanId: "nonexistent")
        XCTAssertEqual(store.loadAll().count, 1, "Should not affect existing records")
    }

    func testDeleteUpdatesGroupedByRFQ() {
        store.save(makeRecord(id: "g1", rfqId: "rfq-A"))
        store.save(makeRecord(id: "g2", rfqId: "rfq-A"))
        store.save(makeRecord(id: "g3", rfqId: "rfq-B"))

        store.delete(scanId: "g1")

        let groups = store.groupedByRFQ()
        let rfqA = groups.first(where: { $0.rfqId == "rfq-A" })
        XCTAssertEqual(rfqA?.scans.count, 1)
        XCTAssertEqual(rfqA?.scans.first?.id, "g2")
    }

    // MARK: - ScanRecord Codable

    func testScanRecordRoundTrip() throws {
        let record = makeRecord(
            id: "codec-test",
            rfqId: "rfq-codec",
            rfqDescription: "Codec Project",
            roomLabel: "Den",
            status: "scan_ready",
            keyframeCount: 42,
            meshTriangleCount: 8000
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ScanRecord.self, from: data)

        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.rfqId, record.rfqId)
        XCTAssertEqual(decoded.rfqDescription, record.rfqDescription)
        XCTAssertEqual(decoded.roomLabel, record.roomLabel)
        XCTAssertEqual(decoded.status, record.status)
        XCTAssertEqual(decoded.keyframeCount, record.keyframeCount)
        XCTAssertEqual(decoded.meshTriangleCount, record.meshTriangleCount)
    }

    // MARK: - ViewModel saveToHistory integration

    func testViewModelSaveToHistory() {
        let vm = ScanViewModel()
        vm.selectedRFQ = RFQ(id: "rfq-vm", description: "VM Project", status: "active", createdAt: nil)
        vm.roomLabel = "Garage"
        vm.updateKeyframeCount(25)
        vm.updateMeshStats(triangleCount: 3000, anchorCount: 8)

        vm.saveToHistory(scanId: "scan-vm-test", status: "scan_ready")

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "scan-vm-test")
        XCTAssertEqual(loaded[0].rfqId, "rfq-vm")
        XCTAssertEqual(loaded[0].roomLabel, "Garage")
        XCTAssertEqual(loaded[0].status, "scan_ready")
        XCTAssertEqual(loaded[0].keyframeCount, 25)
        XCTAssertEqual(loaded[0].meshTriangleCount, 3000)
    }
}
