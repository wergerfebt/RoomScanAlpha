import SwiftUI

/// Homeowner project editor. Shown as a sheet from ProjectDetailView's
/// Edit button. Supports editing the RFQ title + description, plus per-
/// room rename, scope-of-work, and delete.
struct EditProjectView: View {
    let rfq: RFQ
    let detail: ProjectDetail?
    let onSave: () -> Void
    let onClose: () -> Void

    @State private var title: String
    @State private var description: String
    @State private var rooms: [ProjectRoom]
    @State private var saving = false
    @State private var error: String?
    @State private var deleteTarget: ProjectRoom?
    @State private var renameTarget: ProjectRoom?
    @State private var scopeTarget: ProjectRoom?

    init(rfq: RFQ, detail: ProjectDetail?, onSave: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.rfq = rfq
        self.detail = detail
        self.onSave = onSave
        self.onClose = onClose
        _title = State(initialValue: detail?.title ?? rfq.title ?? "")
        _description = State(initialValue: detail?.jobDescription ?? rfq.description ?? "")
        _rooms = State(initialValue: detail?.rooms ?? [])
    }

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        detailsSection
                        if !rooms.isEmpty { roomsSection }
                        if let error, !error.isEmpty {
                            Text(error).font(.caption).foregroundStyle(QTheme.danger)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Edit project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onClose).foregroundStyle(QTheme.ink)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: save) {
                        if saving {
                            ProgressView().tint(QTheme.primary)
                        } else {
                            Text("Save").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(QTheme.primary)
                        }
                    }
                    .disabled(saving || !hasChanges)
                }
            }
            .sheet(item: $renameTarget) { room in
                RenameRoomSheet(room: room) { newLabel in
                    Task { await renameRoom(room: room, label: newLabel) }
                }
            }
            .sheet(item: $scopeTarget) { room in
                ScopeEditorSheet(room: room) { scope in
                    Task { await saveScope(room: room, scope: scope) }
                }
            }
            .alert(
                "Delete room?",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                presenting: deleteTarget
            ) { target in
                Button("Cancel", role: .cancel) {}
                Button("Delete \(target.displayLabel)", role: .destructive) {
                    Task { await deleteRoom(target) }
                }
            } message: { target in
                Text("This removes \(target.displayLabel) from the project. Contractors who already bid will be notified the project changed.")
            }
        }
        .tint(QTheme.primary)
    }

    private var hasChanges: Bool {
        let origTitle = detail?.title ?? rfq.title ?? ""
        let origDesc = detail?.jobDescription ?? rfq.description ?? ""
        return title != origTitle || description != origDesc
    }

    // MARK: – Details section

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Details")
            VStack(alignment: .leading, spacing: 14) {
                fieldLabel("Title")
                TextField("Kitchen Remodel", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(QTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))

                fieldLabel("Description")
                TextField("What do you want done?", text: $description, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.system(size: 16))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(QTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))
            }
        }
    }

    // MARK: – Rooms section

    private var roomsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Rooms")
            VStack(spacing: 10) {
                ForEach(rooms) { room in
                    roomRow(room)
                }
            }
        }
    }

    private func roomRow(_ room: ProjectRoom) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.displayLabel)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(QTheme.ink)
                    Text(roomSubtitle(room))
                        .font(.caption)
                        .foregroundStyle(QTheme.inkMuted)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                chipButton("Rename", icon: "pencil") { renameTarget = room }
                chipButton("Scope", icon: "checklist") { scopeTarget = room }
                chipButton("Delete", icon: "trash", destructive: true) { deleteTarget = room }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(QTheme.hairline, lineWidth: 0.5))
    }

    private func chipButton(_ label: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(destructive ? QTheme.danger : QTheme.primary)
            .background((destructive ? QTheme.danger : QTheme.primary).opacity(0.10))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func roomSubtitle(_ room: ProjectRoom) -> String {
        var parts: [String] = []
        if let sqft = room.floorAreaSqft { parts.append("\(Int(sqft.rounded())) sqft") }
        let items = room.scope?.items?.count ?? 0
        if items > 0 { parts.append("\(items) scope item\(items == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    // MARK: – Actions

    private func save() {
        Task {
            saving = true
            defer { saving = false }
            do {
                try await RFQService.shared.updateRFQ(
                    rfqId: rfq.id,
                    title: title,
                    description: description
                )
                onSave()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func renameRoom(room: ProjectRoom, label: String) async {
        do {
            try await RFQService.shared.renameRoom(rfqId: rfq.id, scanId: room.scanId, label: label)
            if let idx = rooms.firstIndex(where: { $0.scanId == room.scanId }) {
                let updated = ProjectRoom(
                    scanId: room.scanId,
                    roomLabel: label,
                    floorAreaSqft: room.floorAreaSqft,
                    wallAreaSqft: room.wallAreaSqft,
                    ceilingHeightFt: room.ceilingHeightFt,
                    perimeterLinearFt: room.perimeterLinearFt,
                    roomPolygonFt: room.roomPolygonFt,
                    scanStatus: room.scanStatus,
                    hasSplat: room.hasSplat,
                    scope: room.scope
                )
                rooms[idx] = updated
            }
            renameTarget = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveScope(room: ProjectRoom, scope: RoomScope) async {
        do {
            try await RFQService.shared.saveScope(rfqId: rfq.id, scanId: room.scanId, scope: scope)
            if let idx = rooms.firstIndex(where: { $0.scanId == room.scanId }) {
                let summary = RoomScopeSummary(items: scope.items, notes: scope.notes)
                rooms[idx] = ProjectRoom(
                    scanId: room.scanId,
                    roomLabel: room.roomLabel,
                    floorAreaSqft: room.floorAreaSqft,
                    wallAreaSqft: room.wallAreaSqft,
                    ceilingHeightFt: room.ceilingHeightFt,
                    perimeterLinearFt: room.perimeterLinearFt,
                    roomPolygonFt: room.roomPolygonFt,
                    scanStatus: room.scanStatus,
                    hasSplat: room.hasSplat,
                    scope: summary
                )
            }
            scopeTarget = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteRoom(_ room: ProjectRoom) async {
        do {
            try await RFQService.shared.deleteScan(rfqId: rfq.id, scanId: room.scanId)
            rooms.removeAll { $0.scanId == room.scanId }
            deleteTarget = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: – Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold)).tracking(0.5)
            .foregroundStyle(QTheme.inkMuted)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(QTheme.inkSoft)
    }
}

// MARK: – Rename sheet

struct RenameRoomSheet: View {
    let room: ProjectRoom
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String

    init(room: ProjectRoom, onSave: @escaping (String) -> Void) {
        self.room = room
        self.onSave = onSave
        _label = State(initialValue: room.displayLabel)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Name this room anything recognizable — "
                     + "e.g. \"Primary Bath\", \"Living Room\".")
                    .font(.callout)
                    .foregroundStyle(QTheme.inkMuted)

                TextField("Room name", text: $label)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                    .padding(14)
                    .background(QTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))

                Spacer()
            }
            .padding(20)
            .background(QTheme.canvas.ignoresSafeArea())
            .navigationTitle("Rename room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(QTheme.ink)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") {
                        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { onSave(trimmed) }
                    }
                    .fontWeight(.semibold)
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(QTheme.primary)
        .presentationDetents([.medium])
    }
}

// MARK: – Scope editor

struct ScopeEditorSheet: View {
    let room: ProjectRoom
    let onSave: (RoomScope) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var notes: String

    init(room: ProjectRoom, onSave: @escaping (RoomScope) -> Void) {
        self.room = room
        self.onSave = onSave
        _selected = State(initialValue: Set(room.scope?.items ?? []))
        _notes = State(initialValue: room.scope?.notes ?? "")
    }

    private var catalog: [ScopeItemCatalog.Item] {
        ScopeItemCatalog.items(for: room.displayLabel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Pick every change you want on \(room.displayLabel).")
                        .font(.callout)
                        .foregroundStyle(QTheme.inkMuted)

                    LazyVStack(spacing: 0) {
                        ForEach(Array(catalog.enumerated()), id: \.element.id) { idx, item in
                            if idx > 0 { Divider().background(QTheme.divider) }
                            row(item)
                        }
                    }
                    .background(QTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(QTheme.hairline, lineWidth: 0.5))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes").font(.system(size: 13, weight: .semibold)).foregroundStyle(QTheme.inkSoft)
                        TextField("Anything specific the contractor should know?", text: $notes, axis: .vertical)
                            .lineLimit(3...8)
                            .padding(14)
                            .background(QTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))
                    }
                }
                .padding(20)
            }
            .background(QTheme.canvas.ignoresSafeArea())
            .navigationTitle("Scope — \(room.displayLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(QTheme.ink)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") {
                        let items = catalog.map(\.id).filter { selected.contains($0) }
                        onSave(RoomScope(items: items, notes: notes))
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(QTheme.primary)
    }

    private func row(_ item: ScopeItemCatalog.Item) -> some View {
        Button {
            if selected.contains(item.id) { selected.remove(item.id) }
            else { selected.insert(item.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected.contains(item.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(selected.contains(item.id) ? QTheme.primary : QTheme.inkDim)
                Text(item.label)
                    .font(.system(size: 15))
                    .foregroundStyle(QTheme.ink)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
