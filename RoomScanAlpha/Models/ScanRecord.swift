import Foundation

struct ScanRecord: Codable, Identifiable {
    let id: String          // scan_id
    let rfqId: String
    let rfqDescription: String?
    let roomLabel: String
    let status: String      // processing, scan_ready, failed
    let keyframeCount: Int
    let meshTriangleCount: Int
    let timestamp: Date

    var statusDisplay: String {
        switch status {
        case "scan_ready": return "Complete"
        case "processing": return "Processing"
        case "failed": return "Failed"
        case "uploading": return "Uploading"
        default: return status.capitalized
        }
    }

    var statusIcon: String {
        switch status {
        case "scan_ready": return "checkmark.circle.fill"
        case "processing": return "clock.fill"
        case "failed": return "xmark.circle.fill"
        default: return "circle.fill"
        }
    }
}

final class ScanHistoryStore {
    static let shared = ScanHistoryStore()
    private let key = "scanHistory"

    private init() {}

    func save(_ record: ScanRecord) {
        var records = loadAll()
        // Update existing or append
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        // Keep last 100
        if records.count > 100 {
            records = Array(records.prefix(100))
        }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func loadAll() -> [ScanRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([ScanRecord].self, from: data) else {
            return []
        }
        return records
    }

    /// Group records by RFQ ID.
    func groupedByRFQ() -> [(rfqId: String, rfqDescription: String?, scans: [ScanRecord])] {
        let records = loadAll()
        var groups = [String: (desc: String?, scans: [ScanRecord])]()
        for record in records {
            var group = groups[record.rfqId] ?? (desc: record.rfqDescription, scans: [])
            group.scans.append(record)
            groups[record.rfqId] = group
        }
        return groups.map { (rfqId: $0.key, rfqDescription: $0.value.desc, scans: $0.value.scans) }
            .sorted { ($0.scans.first?.timestamp ?? .distantPast) > ($1.scans.first?.timestamp ?? .distantPast) }
    }
}
