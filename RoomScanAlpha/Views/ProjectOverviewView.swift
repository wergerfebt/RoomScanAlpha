import SwiftUI

struct ProjectOverviewView: View {
    let rfq: RFQ
    let onScanRoom: () -> Void
    let onBack: () -> Void

    @State private var rooms: [RoomSummary] = []
    @State private var isLoading = true
    @State private var roomToDelete: RoomSummary?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading rooms...")
                } else {
                    List {
                        // Project info header
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(rfq.displayTitle)
                                    .font(.title3)
                                    .fontWeight(.bold)

                                if let address = rfq.address, !address.isEmpty {
                                    if let mapsURL = URL(string: "https://maps.google.com/?q=\(address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                                        Link(destination: mapsURL) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "mappin")
                                                    .font(.caption)
                                                Text(address)
                                                    .font(.subheadline)
                                            }
                                            .foregroundStyle(.blue)
                                        }
                                    }
                                }

                                if let desc = rfq.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        // Rooms
                        if rooms.isEmpty {
                            Section {
                                Text("No rooms scanned yet")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Section("Rooms") {
                                ForEach(rooms) { room in
                                    NavigationLink {
                                        RoomDetailView(room: room, rfqId: rfq.id)
                                    } label: {
                                        HStack {
                                            statusIcon(for: room.status)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(room.roomLabel)
                                                    .font(.headline)
                                                if let area = room.floorAreaSqft {
                                                    Text("\(Int(area)) sqft")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                } else {
                                                    Text(room.statusDisplay)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            roomToDelete = room
                                            showDeleteConfirm = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }

                        // Scan button
                        Section {
                            Button(action: onScanRoom) {
                                Label("Scan Another Room", systemImage: "camera.viewfinder")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { onBack() }
                }
            }
            .alert("Delete Room?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let room = roomToDelete {
                        deleteRoom(room)
                    }
                }
                Button("Cancel", role: .cancel) { roomToDelete = nil }
            } message: {
                Text("Delete \"\(roomToDelete?.roomLabel ?? "this room")\" and its scan data?")
            }
            .task {
                await loadRooms()
            }
        }
    }

    private func loadRooms() async {
        // Load from local scan history first
        let localRecords = ScanHistoryStore.shared.loadAll()
            .filter { $0.rfqId == rfq.id }
        rooms = localRecords.map { record in
            RoomSummary(
                id: record.id,
                roomLabel: record.roomLabel.isEmpty ? "Untitled Room" : record.roomLabel,
                status: record.status,
                floorAreaSqft: nil,
                ceilingHeightFt: nil,
                wallAreaSqft: nil,
                perimeterFt: nil,
                scopeItems: [],
                scopeNotes: nil,
                polygonFt: nil
            )
        }
        isLoading = false

        // Fetch from cloud for latest status + dimensions + scope
        do {
            let url = URL(string: "https://scan-api-839349778883.us-central1.run.app/api/rfqs/\(rfq.id)/contractor-view")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard let roomsArray = json["rooms"] as? [[String: Any]] else { return }

            // Preserve local labels for scans uploaded before room_label was sent to cloud
            let localLabels = Dictionary(rooms.map { ($0.id, $0.roomLabel) }, uniquingKeysWith: { _, last in last })

            rooms = roomsArray.compactMap { dict in
                guard let id = dict["scan_id"] as? String ?? dict["id"] as? String else { return nil }
                let label = dict["room_label"] as? String
                let scope = dict["scope"] as? [String: Any]
                return RoomSummary(
                    id: id,
                    roomLabel: (label?.isEmpty == false) ? label! : (localLabels[id] ?? "Untitled Room"),
                    status: dict["scan_status"] as? String ?? "unknown",
                    floorAreaSqft: dict["floor_area_sqft"] as? Double,
                    ceilingHeightFt: dict["ceiling_height_ft"] as? Double,
                    wallAreaSqft: dict["wall_area_sqft"] as? Double,
                    perimeterFt: dict["perimeter_linear_ft"] as? Double,
                    scopeItems: scope?["items"] as? [String] ?? [],
                    scopeNotes: scope?["notes"] as? String,
                    polygonFt: dict["room_polygon_ft"] as? [[Double]]
                )
            }
        } catch {
            print("[RoomScanAlpha] Failed to fetch rooms: \(error)")
        }
    }

    private func deleteRoom(_ room: RoomSummary) {
        Task {
            do {
                try await RFQService.shared.deleteScan(rfqId: rfq.id, scanId: room.id)
                rooms.removeAll { $0.id == room.id }
                ScanHistoryStore.shared.delete(scanId: room.id)
            } catch {
                print("[RoomScanAlpha] Failed to delete room: \(error)")
            }
        }
        roomToDelete = nil
    }

    private func statusIcon(for status: String) -> some View {
        let (icon, color): (String, Color) = switch status {
        case "complete", "scan_ready": ("checkmark.circle.fill", .green)
        case "processing": ("clock.fill", .orange)
        case "failed": ("xmark.circle.fill", .red)
        default: ("circle.fill", .gray)
        }
        return Image(systemName: icon)
            .foregroundStyle(color)
    }
}

// MARK: - Room Detail View

struct RoomDetailView: View {
    let room: RoomSummary
    let rfqId: String

    var body: some View {
        List {
            // Dimensions
            if room.status == "complete" || room.status == "scan_ready" {
                Section("Dimensions") {
                    if let area = room.floorAreaSqft {
                        dimensionRow(label: "Floor Area", value: "\(Int(area)) sqft")
                    }
                    if let walls = room.wallAreaSqft {
                        dimensionRow(label: "Wall Area", value: "\(Int(walls)) sqft")
                    }
                    if let height = room.ceilingHeightFt {
                        dimensionRow(label: "Ceiling Height", value: String(format: "%.1f ft", height))
                    }
                    if let perimeter = room.perimeterFt {
                        dimensionRow(label: "Perimeter", value: String(format: "%.1f ft", perimeter))
                    }
                }
            }

            // Scope of work
            if !room.scopeItems.isEmpty || (room.scopeNotes?.isEmpty == false) {
                Section("Scope of Work") {
                    if !room.scopeItems.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(room.scopeItems, id: \.self) { item in
                                Text(item.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    if let notes = room.scopeNotes, !notes.isEmpty {
                        Text(notes)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Status
            Section("Status") {
                HStack {
                    Text("Scan Status")
                    Spacer()
                    Text(room.statusDisplay)
                        .foregroundStyle(.secondary)
                }
            }

            // Floor plan
            if let polygon = room.polygonFt, polygon.count >= 3 {
                Section("Floor Plan") {
                    FloorPlanCanvasView(polygon: polygon, roomLabel: room.roomLabel)
                        .frame(height: 250)
                }
            }

            // 3D Viewer
            if room.status == "complete" || room.status == "scan_ready" {
                Section {
                    Link(destination: URL(string: "https://scan-api-839349778883.us-central1.run.app/quote/\(rfqId)")!) {
                        Label("Open 3D Viewer", systemImage: "cube.transparent")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle(room.roomLabel)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func dimensionRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Room Summary Model

struct RoomSummary: Identifiable {
    let id: String
    let roomLabel: String
    let status: String
    let floorAreaSqft: Double?
    let ceilingHeightFt: Double?
    let wallAreaSqft: Double?
    let perimeterFt: Double?
    let scopeItems: [String]
    let scopeNotes: String?
    let polygonFt: [[Double]]?

    var statusDisplay: String {
        switch status {
        case "complete", "scan_ready": return "Complete"
        case "processing": return "Processing"
        case "failed": return "Failed"
        default: return status.capitalized
        }
    }
}

// MARK: - Floor Plan Canvas

struct FloorPlanCanvasView: View {
    let polygon: [[Double]]
    let roomLabel: String

    var body: some View {
        Canvas { context, size in
            guard polygon.count >= 3 else { return }

            let xs = polygon.map { $0[0] }
            let ys = polygon.map { $0[1] }
            let minX = xs.min()!, maxX = xs.max()!
            let minY = ys.min()!, maxY = ys.max()!
            let polyW = maxX - minX
            let polyH = maxY - minY
            guard polyW > 0, polyH > 0 else { return }

            // Fit polygon into canvas with padding
            let padding: CGFloat = 30
            let drawW = size.width - padding * 2
            let drawH = size.height - padding * 2
            let scale = min(drawW / polyW, drawH / polyH)
            let offsetX = padding + (drawW - polyW * scale) / 2
            let offsetY = padding + (drawH - polyH * scale) / 2

            func toCanvas(_ pt: [Double]) -> CGPoint {
                CGPoint(
                    x: offsetX + (pt[0] - minX) * scale,
                    y: offsetY + (pt[1] - minY) * scale
                )
            }

            // Draw filled polygon
            var path = Path()
            path.move(to: toCanvas(polygon[0]))
            for i in 1..<polygon.count {
                path.addLine(to: toCanvas(polygon[i]))
            }
            path.closeSubpath()

            context.fill(path, with: .color(.blue.opacity(0.1)))
            context.stroke(path, with: .color(.blue), lineWidth: 2)

            // Draw wall dimensions
            for i in 0..<polygon.count {
                let j = (i + 1) % polygon.count
                let p0 = polygon[i]
                let p1 = polygon[j]
                let dx = p1[0] - p0[0]
                let dy = p1[1] - p0[1]
                let wallLen = sqrt(dx * dx + dy * dy)

                let mid = toCanvas([(p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2])
                let label = String(format: "%.1f'", wallLen)

                // Offset label slightly perpendicular to wall
                let nx = -dy / wallLen * 12.0
                let ny = dx / wallLen * 12.0
                let labelPt = CGPoint(x: mid.x + nx, y: mid.y + ny)

                context.draw(
                    Text(label)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary),
                    at: labelPt
                )
            }

            // Draw corner dots
            for pt in polygon {
                let cp = toCanvas(pt)
                context.fill(
                    Path(ellipseIn: CGRect(x: cp.x - 3, y: cp.y - 3, width: 6, height: 6)),
                    with: .color(.blue)
                )
            }
        }
        .background(Color(uiColor: .systemBackground))
        .cornerRadius(8)
    }
}
