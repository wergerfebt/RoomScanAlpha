import SwiftUI

/// Contractor-side job detail — parallel to `ProjectDetailView` on the
/// homeowner side, but focused on what a contractor needs to quote: room
/// scan (floor plan + BEV), scope of work per selected room, the current
/// bid state, and a way to open a chat with the homeowner.
///
/// Reuses `/api/rfqs/{id}/contractor-view` for scan data since the endpoint
/// is already link-as-auth and returns the exact shape `ProjectDetail`
/// expects.
struct JobDetailView: View {
    let job: Job

    @State private var detail: ProjectDetail?
    @State private var loading = true
    @State private var error: String?
    @State private var selectedScanId: String?
    @State private var scanView: ScanView = .floorplan
    @State private var interactingWithBEV = false
    @State private var bevFullscreen = false
    @State private var openingConversation = false
    @State private var conversationRoute: ConversationRoute?

    private enum ScanView: String { case floorplan, birdseye }

    private struct ConversationRoute: Identifiable {
        let id: String
        let title: String
    }

    private let embedBase = "https://scan-api-839349778883.us-central1.run.app"

    private var selectedRoom: ProjectRoom? {
        guard let detail else { return nil }
        if let id = selectedScanId, let hit = detail.rooms.first(where: { $0.scanId == id }) {
            return hit
        }
        return detail.rooms.first
    }

    private var bevURL: URL? {
        var params = "view=bev&measurements=on"
        if let room = selectedRoom { params += "&room=\(room.scanId)" }
        return URL(string: "\(embedBase)/embed/scan/\(job.rfqId)?\(params)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if let detail, !detail.rooms.isEmpty {
                    scanBand(detail: detail)
                }
                scopeSection
                bidSection
                messageButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 60)
        }
        .scrollDisabled(interactingWithBEV)
        .background(QTheme.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .fullScreenCover(isPresented: $bevFullscreen) {
            if let url = bevURL {
                JobBEVFullscreenView(url: url) { bevFullscreen = false }
            }
        }
        .sheet(item: $conversationRoute) { route in
            NavigationStack {
                ConversationView(conversationId: route.id, initialTitle: route.title)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { conversationRoute = nil }
                                .foregroundStyle(QTheme.ink)
                        }
                    }
            }
            .tint(QTheme.primary)
        }
    }

    // MARK: – Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusChip
                if job.rfqDeleted == true {
                    chip(text: "CANCELLED", color: QTheme.danger)
                }
                if job.bid?.rfqModifiedAfterBid == true {
                    chip(text: "PROJECT UPDATED", color: QTheme.warning)
                }
                Spacer()
            }

            Text(job.title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(QTheme.ink)

            if let description = job.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(QTheme.inkSoft)
                    .lineSpacing(2)
                    .padding(.top, 4)
            }

            if let address = job.address, !address.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse").font(.caption)
                    Text(address).font(.subheadline)
                }
                .foregroundStyle(QTheme.inkMuted)
                .padding(.top, 2)
            }
        }
    }

    private var statusChip: some View {
        let tint: Color = {
            switch job.jobStatus {
            case "won": return QTheme.success
            case "pending": return QTheme.warning
            case "lost": return QTheme.inkMuted
            default: return QTheme.scanAccent
            }
        }()
        return chip(text: job.jobStatus.uppercased(), color: tint)
    }

    private func chip(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.4)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: – Scan band

    private func scanBand(detail: ProjectDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Scan")
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 2) {
                    tabButton("Floor plan", active: scanView == .floorplan) { scanView = .floorplan }
                    tabButton("Bird's eye", active: scanView == .birdseye) { scanView = .birdseye }
                }
                .padding(3)
                .background(QTheme.surfaceMuted)
                .clipShape(Capsule())

                Group {
                    switch scanView {
                    case .floorplan:
                        JobFloorPlanView(rooms: detail.rooms, selectedId: selectedRoom?.scanId)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    case .birdseye:
                        if let url = bevURL {
                            ZStack(alignment: .topTrailing) {
                                EmbedWebView(url: url)
                                    .background(Color.black)
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { _ in if !interactingWithBEV { interactingWithBEV = true } }
                                            .onEnded { _ in interactingWithBEV = false }
                                    )
                                Button {
                                    bevFullscreen = true
                                } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(10)
                                        .background(.ultraThinMaterial)
                                        .background(Color.black.opacity(0.35))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .padding(10)
                                .accessibilityLabel("Enter full screen")
                            }
                            .frame(height: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
                .onChange(of: scanView) { _, newValue in
                    if newValue != .birdseye { interactingWithBEV = false }
                }

                statsGrid

                VStack(spacing: 0) {
                    ForEach(Array(detail.rooms.enumerated()), id: \.element.id) { idx, room in
                        if idx > 0 { Divider().background(QTheme.divider) }
                        roomRow(room)
                    }
                }
                .background(QTheme.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(18)
            .background(QTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: QTheme.radiusXLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: QTheme.radiusXLarge, style: .continuous).strokeBorder(QTheme.hairline))
        }
    }

    private func tabButton(_ label: String, active: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? QTheme.ink : QTheme.inkMuted)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(active ? QTheme.surface : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func roomRow(_ room: ProjectRoom) -> some View {
        let isSelected = selectedRoom?.scanId == room.scanId
        return Button {
            selectedScanId = room.scanId
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(isSelected ? QTheme.scanAccent : QTheme.success)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.displayLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(QTheme.ink)
                    Text(roomSubtitle(room))
                        .font(.caption)
                        .foregroundStyle(QTheme.inkMuted)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(QTheme.scanAccent)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(isSelected ? QTheme.scanAccentSoft : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var statsGrid: some View {
        let room = selectedRoom
        let items: [(String, String, String)] = [
            ("Floor area", room?.floorAreaSqft.map(formatNum) ?? "—", "sqft"),
            ("Wall area", room?.wallAreaSqft.map(formatNum) ?? "—", "sqft"),
            ("Ceiling", room?.ceilingHeightFt.map { String(format: "%.1f", $0) } ?? "—", "ft"),
            ("Perimeter", room?.perimeterLinearFt.map(formatNum) ?? "—", "ft"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(items, id: \.0) { item in
                statTile(label: item.0, value: item.1, unit: item.2)
            }
        }
    }

    private func statTile(label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold)).tracking(0.3)
                .foregroundStyle(QTheme.inkMuted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 22, weight: .bold)).tracking(-0.5)
                    .foregroundStyle(QTheme.ink)
                if !unit.isEmpty {
                    Text(unit).font(.caption).foregroundStyle(QTheme.inkMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(QTheme.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: QTheme.radiusMedium, style: .continuous))
    }

    // MARK: – Scope

    @ViewBuilder
    private var scopeSection: some View {
        let scope = selectedRoom?.scope
        if let scope, (scope.items?.isEmpty == false) || (scope.notes?.isEmpty == false) {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel(scopeTitle)
                VStack(alignment: .leading, spacing: 10) {
                    if let items = scope.items, !items.isEmpty {
                        JobChipFlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(items, id: \.self) { item in
                                Text(formatScopeLabel(item))
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(QTheme.primarySoft)
                                    .foregroundStyle(QTheme.primary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    if let note = scope.notes, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 13))
                            .foregroundStyle(QTheme.inkMuted)
                            .italic()
                            .padding(.top, 4)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: QTheme.radiusXLarge, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: QTheme.radiusXLarge, style: .continuous).strokeBorder(QTheme.hairline))
            }
        }
    }

    private var scopeTitle: String {
        if let name = selectedRoom?.displayLabel { return "Scope of work — \(name)" }
        return "Scope of work"
    }

    // MARK: – Bid

    @ViewBuilder
    private var bidSection: some View {
        if let bid = job.bid {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("Your bid")
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("$\(bid.priceCents / 100)")
                            .font(.system(size: 30, weight: .bold))
                            .tracking(-0.8)
                            .foregroundStyle(QTheme.ink)
                            .monospacedDigit()
                        Spacer()
                        if let status = bid.status {
                            chip(text: status.uppercased(), color: bidStatusColor(status))
                        }
                    }
                    if let desc = bid.description, !desc.isEmpty {
                        Text(desc)
                            .font(.callout)
                            .foregroundStyle(QTheme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let pdf = bid.pdfURL, let url = URL(string: pdf) {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.fill").foregroundStyle(QTheme.danger)
                                Text("View breakdown PDF")
                                    .font(.callout).fontWeight(.semibold)
                                    .foregroundStyle(QTheme.ink)
                                Spacer()
                                Image(systemName: "arrow.up.right.square").foregroundStyle(QTheme.inkMuted)
                            }
                            .padding(12)
                            .background(QTheme.surfaceMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding(18)
                .background(QTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: QTheme.radiusXLarge, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: QTheme.radiusXLarge, style: .continuous).strokeBorder(QTheme.hairline))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not bid yet").font(.headline).foregroundStyle(QTheme.ink)
                Text("Submit a quote from the web dashboard at roomscanalpha.com — the bid form with PDF attachments lives there.")
                    .font(.callout).foregroundStyle(QTheme.inkMuted)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: QTheme.radiusXLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: QTheme.radiusXLarge, style: .continuous).strokeBorder(QTheme.hairline))
        }
    }

    private func bidStatusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "accepted": return QTheme.success
        case "rejected": return QTheme.danger
        default: return QTheme.warning
        }
    }

    // MARK: – Message button

    private var messageButton: some View {
        Button {
            Task { await openConversation() }
        } label: {
            HStack(spacing: 8) {
                if openingConversation {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "envelope.fill").font(.system(size: 15, weight: .semibold))
                }
                Text(openingConversation ? "Opening…" : "Message homeowner")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(QTheme.primaryInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(QTheme.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(openingConversation)
        .alert("Couldn't open chat", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func openConversation() async {
        openingConversation = true
        defer { openingConversation = false }
        do {
            // The caller's org is the authenticated org — the backend looks
            // up the org via the caller's firebase_uid → org_member row
            // when we don't know the org_id client-side. OrgService.getOrg()
            // returns our current org's profile.
            let org = try await OrgService.shared.getOrg()
            let id = try await InboxService.shared.createConversation(rfqId: job.rfqId, orgId: org.id)
            conversationRoute = ConversationRoute(id: id, title: job.title)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: – Data

    private func load() async {
        loading = true
        do {
            detail = try await RFQService.shared.getProjectDetail(rfqId: job.rfqId)
            if selectedScanId == nil, let first = detail?.rooms.first {
                selectedScanId = first.scanId
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    // MARK: – Small helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold)).tracking(0.5)
            .foregroundStyle(QTheme.inkMuted)
    }

    private func roomSubtitle(_ room: ProjectRoom) -> String {
        var parts: [String] = []
        if let sqft = room.floorAreaSqft { parts.append("\(Int(sqft.rounded())) sqft") }
        switch room.scanStatus {
        case "complete", "completed": parts.append("Scan complete")
        default: parts.append(room.scanStatus.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        return parts.joined(separator: " · ")
    }

    private func formatNum(_ value: Double) -> String {
        if value <= 0 { return "—" }
        if value < 100 { return String(format: "%.1f", value) }
        return "\(Int(value.rounded()))"
    }

    private func formatScopeLabel(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: – Fullscreen BEV

private struct JobBEVFullscreenView: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            EmbedWebView(url: url).ignoresSafeArea()
            Button {
                onDismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    Text("Close").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .background(Color.black.opacity(0.35))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8).padding(.leading, 16)
        }
        .statusBarHidden(true)
    }
}

// MARK: – Flow layout for scope chips

private struct JobChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && rowWidth > 0 {
                totalHeight += rowHeight + lineSpacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        let maxX = bounds.maxX
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: – Floor plan with selection highlight

private struct JobFloorPlanView: View {
    let rooms: [ProjectRoom]
    let selectedId: String?

    var body: some View {
        GeometryReader { geom in
            Canvas { ctx, size in
                draw(in: ctx, size: size)
            }
            .frame(width: geom.size.width, height: geom.size.height)
        }
        .background(QTheme.scanAccentSoft)
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let gapFt: CGFloat = 3
        var placed: [(poly: [CGPoint], label: String, id: String)] = []
        var cursorX: CGFloat = 0
        for r in rooms {
            guard let poly = r.roomPolygonFt, poly.count >= 3 else { continue }
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity
            for p in poly where p.count >= 2 {
                minX = min(minX, CGFloat(p[0])); maxX = max(maxX, CGFloat(p[0]))
                minY = min(minY, CGFloat(p[1]))
            }
            let offX = cursorX - minX
            let offY = -minY
            let shifted = poly.compactMap { p -> CGPoint? in
                guard p.count >= 2 else { return nil }
                return CGPoint(x: CGFloat(p[0]) + offX, y: CGFloat(p[1]) + offY)
            }
            placed.append((shifted, r.displayLabel, r.scanId))
            cursorX += (maxX - minX) + gapFt
        }
        guard !placed.isEmpty else { return }

        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for (poly, _, _) in placed {
            for p in poly {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        let spanX = max(maxX - minX, 1), spanY = max(maxY - minY, 1)
        let pad: CGFloat = 0.18
        let w = size.width * (1 - 2 * pad)
        let h = size.height * (1 - 2 * pad)
        let scale = min(w / spanX, h / spanY)
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        func tx(_ x: CGFloat) -> CGFloat { size.width / 2 + (x - cx) * scale }
        func ty(_ y: CGFloat) -> CGFloat { size.height / 2 + (y - cy) * scale }

        let accent = QTheme.scanAccent

        for (poly, label, id) in placed {
            let isSel = id == selectedId
            var path = Path()
            for (i, p) in poly.enumerated() {
                let pt = CGPoint(x: tx(p.x), y: ty(p.y))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            path.closeSubpath()
            ctx.fill(path, with: .color(accent.opacity(isSel ? 0.25 : 0.10)))
            ctx.stroke(path, with: .color(accent), lineWidth: isSel ? 2.5 : 1.5)

            let labelFont = Font.system(size: 10, weight: .semibold)
            for j in 0..<poly.count {
                let k = (j + 1) % poly.count
                let a = poly[j], b = poly[k]
                let wallFt = hypot(b.x - a.x, b.y - a.y)
                if wallFt < 1 { continue }
                let screenA = CGPoint(x: tx(a.x), y: ty(a.y))
                let screenB = CGPoint(x: tx(b.x), y: ty(b.y))
                let mid = CGPoint(x: (screenA.x + screenB.x) / 2, y: (screenA.y + screenB.y) / 2)
                let dx = screenB.x - screenA.x, dy = screenB.y - screenA.y
                let len = max(hypot(dx, dy), 1)
                if len < 30 { continue }
                let nx = -dy / len * 9
                let ny = dx / len * 9
                let pos = CGPoint(x: mid.x + nx, y: mid.y + ny)
                let text = Text(String(format: "%.1f'", wallFt))
                    .font(labelFont)
                    .foregroundColor(QTheme.inkSoft)
                ctx.draw(text, at: pos, anchor: .center)
            }

            let sum = poly.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let centroid = CGPoint(x: sum.x / CGFloat(poly.count), y: sum.y / CGFloat(poly.count))
            let labelText = Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(QTheme.ink)
            ctx.draw(labelText, at: CGPoint(x: tx(centroid.x), y: ty(centroid.y)), anchor: .center)
        }
    }
}
