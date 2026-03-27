import SwiftUI

struct ScanHistoryView: View {
    @State private var groups: [(rfqId: String, rfqDescription: String?, scans: [ScanRecord])] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if groups.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "clock")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No scan history")
                            .font(.headline)
                        Text("Completed scans will appear here")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        ForEach(groups, id: \.rfqId) { group in
                            Section {
                                ForEach(group.scans) { scan in
                                    scanRow(scan)
                                }
                            } header: {
                                Text(group.rfqDescription ?? "Untitled Project")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scan History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                groups = ScanHistoryStore.shared.groupedByRFQ()
            }
        }
    }

    private func scanRow(_ scan: ScanRecord) -> some View {
        HStack {
            Image(systemName: scan.statusIcon)
                .foregroundStyle(scan.status == "scan_ready" ? .green : scan.status == "failed" ? .red : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(scan.roomLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("\(scan.keyframeCount) frames  •  \(scan.meshTriangleCount) triangles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(scan.statusDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(scan.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
