import SwiftUI

/// Homeowner-facing project detail. Opens from the RFQ list.
/// Matches the web `ProjectDetail` layout: header → scan band → scope → bids.
/// The big product shift is that bids now live on-device (previously web-only).
struct ProjectDetailView: View {
    let rfq: RFQ

    @State private var detail: ProjectDetail?
    @State private var bids: [Bid] = []
    @State private var loading = true
    @State private var error: String?
    @State private var hireConfirmation: Bid?
    @State private var hiring = false
    @State private var hiredError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let detail, !detail.rooms.isEmpty {
                    scanBand(detail: detail)
                }
                if let scopeText = scopeText, !scopeText.isEmpty {
                    scopeSection(scopeText: scopeText)
                }
                bidsSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 60)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(
            "Accept this quote?",
            isPresented: Binding(
                get: { hireConfirmation != nil },
                set: { if !$0 { hireConfirmation = nil } }
            ),
            presenting: hireConfirmation
        ) { bid in
            Button("Cancel", role: .cancel) {}
            Button("Hire \(bid.contractor.displayName)") {
                Task { await hire(bid: bid) }
            }
        } message: { bid in
            Text("You'll hire \(bid.contractor.displayName) for \(bid.displayPrice). Other contractors will be notified that you chose someone else.")
        }
        .alert("Couldn't hire contractor", isPresented: Binding(
            get: { hiredError != nil },
            set: { if !$0 { hiredError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(hiredError ?? "")
        }
    }

    // MARK: – Derived state

    private var scopeText: String? {
        if let s = detail?.projectScope, !s.isEmpty { return s }
        if let d = detail?.jobDescription, !d.isEmpty { return d }
        if let rd = rfq.description, !rd.isEmpty { return rd }
        return nil
    }

    private var sortedBids: [Bid] {
        bids.sorted { $0.priceCents < $1.priceCents }
    }

    private var lowestPriceCents: Int? {
        bids.map(\.priceCents).min()
    }

    // MARK: – Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rfq.displayTitle)
                .font(.system(size: 32, weight: .bold))
                .lineSpacing(2)
                .tracking(-0.8)

            if let description = rfq.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .padding(.top, 4)
            }

            HStack(spacing: 6) {
                if let address = rfq.address, !address.isEmpty {
                    metaChip(Image(systemName: "mappin.and.ellipse"), address)
                    if detail != nil { dot }
                }
                if let detail, !detail.rooms.isEmpty {
                    Text("\(detail.rooms.count) \(detail.rooms.count == 1 ? "room" : "rooms")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let created = shortDate(rfq.createdAt) { dot; Text(created).font(.subheadline).foregroundStyle(.secondary) }
                } else if let created = shortDate(rfq.createdAt) {
                    Text(created).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }

    private func scanBand(detail: ProjectDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Scan")
            VStack(alignment: .leading, spacing: 12) {
                // Floor-plan "thumbnail" using the same rendering as the rest
                // of the app. FloorPlanView already renders room polygons.
                ProjectFloorPlanView(polygons: detail.rooms.compactMap { $0.roomPolygonFt })
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                statsGrid(detail: detail)

                if !detail.rooms.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(detail.rooms.enumerated()), id: \.element.id) { idx, room in
                            if idx > 0 { Divider() }
                            roomRow(room)
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(18)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func roomRow(_ room: ProjectRoom) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(room.displayLabel)
                    .font(.system(size: 15, weight: .semibold))
                Text(roomSubtitle(room))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let items = room.scope?.items, !items.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(items.prefix(3), id: \.self) { it in
                            Text(formatScopeLabel(it))
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        if items.count > 3 {
                            Text("+\(items.count - 3)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }

    private func statsGrid(detail: ProjectDetail) -> some View {
        let items: [(String, String, String)] = [
            ("Total floor", formattedNumber(detail.totalFloorSqft), "sqft"),
            ("Rooms", "\(detail.rooms.count)", ""),
            ("Wall area", formattedNumber(detail.rooms.reduce(0) { $0 + ($1.wallAreaSqft ?? 0) }), "sqft"),
            ("Ceiling", detail.averageCeilingFt.map { String(format: "%.1f", $0) } ?? "—", "ft")
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
                .font(.system(size: 10, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 22, weight: .bold)).tracking(-0.5)
                if !unit.isEmpty {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func scopeSection(scopeText: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Scope of work")
            Text(scopeText)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var bidsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Bids")
            if loading && bids.isEmpty {
                ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
            } else if bids.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No bids yet").font(.headline)
                    Text("Contractors submit quotes after reviewing your 3D scan. Most arrive within 48 hours.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                headlinePrice
                VStack(spacing: 12) {
                    ForEach(sortedBids) { bid in
                        bidCard(bid)
                    }
                }
            }
            if let error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var headlinePrice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(bids.count) \(bids.count == 1 ? "bid" : "bids")")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.5)
            if let low = lowestPriceCents {
                Text("· low")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
                Text(priceString(low))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
            }
            Spacer()
        }
    }

    private func bidCard(_ bid: Bid) -> some View {
        let parsed = ParsedBidNote(from: bid.description)
        let isLowest = bid.priceCents == lowestPriceCents && bids.count > 1
        let accepted = bid.isAccepted
        let anyAccepted = bids.contains(where: { $0.isAccepted })

        return VStack(alignment: .leading, spacing: 14) {
            if isLowest && !accepted {
                flag(text: "LOWEST BID", color: .accentColor)
            } else if accepted {
                flag(text: "HIRED", color: .green)
            }

            HStack(spacing: 12) {
                contractorAvatar(bid.contractor).frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bid.contractor.displayName).font(.system(size: 15, weight: .semibold))
                    if let rating = bid.contractor.reviewRating {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                            Text(String(format: "%.1f", rating)).font(.caption).fontWeight(.semibold)
                            if let count = bid.contractor.reviewCount {
                                Text("· \(count) reviews").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("No reviews yet").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Text(bid.displayPrice)
                .font(.system(size: 34, weight: .bold))
                .tracking(-1)
                .monospacedDigit()

            if let submitted = shortDate(bid.receivedAt) {
                Text("Submitted \(submitted)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !parsed.timeline.isEmpty || !parsed.start.isEmpty {
                HStack(spacing: 10) {
                    if !parsed.timeline.isEmpty { inlineMeta("TIMELINE", parsed.timeline) }
                    if !parsed.start.isEmpty { inlineMeta("START", parsed.start) }
                }
            }

            if !parsed.note.isEmpty {
                Text(parsed.note)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            if let pdf = bid.pdfURL, let url = URL(string: pdf) {
                Link(destination: url) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill").foregroundStyle(.red)
                        Text("View project breakdown PDF").font(.callout).fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .foregroundStyle(.primary)
            }

            HStack(spacing: 8) {
                Button {
                    hireConfirmation = bid
                } label: {
                    Text(accepted ? "Hired" : "Hire")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(accepted ? Color.green : Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(hiring || accepted || anyAccepted)
            }
        }
        .padding(18)
        .background(Color(.systemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    accepted ? Color.green : (isLowest ? Color.accentColor : .clear),
                    lineWidth: 2
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: – Tiny helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }

    private func metaChip(_ icon: Image, _ text: String) -> some View {
        HStack(spacing: 4) {
            icon.font(.caption)
            Text(text).font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }

    private var dot: some View {
        Circle().fill(Color.secondary.opacity(0.4)).frame(width: 3, height: 3)
    }

    private func inlineMeta(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10, weight: .bold)).tracking(0.3).foregroundStyle(.secondary)
            Text(value).font(.subheadline).fontWeight(.medium)
        }
    }

    private func flag(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.4)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func contractorAvatar(_ contractor: ContractorSummary) -> some View {
        if let urlString = contractor.iconURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initialsAvatar(contractor.initials)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            initialsAvatar(contractor.initials)
        }
    }

    private func initialsAvatar(_ initials: String) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.accentColor.opacity(0.16))
            .overlay(Text(initials).font(.headline).foregroundStyle(Color.accentColor))
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

    private func shortDate(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: date)
    }

    private func priceString(_ cents: Int) -> String {
        let dollars = Double(cents) / 100.0
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: dollars)) ?? "$\(cents/100)"
    }

    private func formattedNumber(_ value: Double) -> String {
        if value <= 0 { return "—" }
        if value < 100 { return String(format: "%.1f", value) }
        return "\(Int(value.rounded()))"
    }

    private func formatScopeLabel(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: – Data

    private func load() async {
        loading = true
        error = nil
        // Kick off both fetches concurrently — they don't depend on each other.
        async let detailTask = RFQService.shared.getProjectDetail(rfqId: rfq.id)
        async let bidsTask = RFQService.shared.getBids(rfqId: rfq.id)
        do {
            let (d, b) = try await (detailTask, bidsTask)
            detail = d
            bids = b
        } catch {
            self.error = (error as NSError).localizedDescription
        }
        loading = false
    }

    private func hire(bid: Bid) async {
        hiring = true
        hiredError = nil
        do {
            try await RFQService.shared.acceptBid(rfqId: rfq.id, bidId: bid.id)
            // Refresh to reflect the new accepted/rejected statuses.
            bids = (try? await RFQService.shared.getBids(rfqId: rfq.id)) ?? bids
        } catch {
            hiredError = (error as NSError).localizedDescription
        }
        hiring = false
    }
}

/// Flat top-down polygon sketch matching the web's scan-accent indigo color.
/// The existing `FloorPlanView` in this module has a different signature
/// (built around annotations); this renders from raw point lists.
private struct ProjectFloorPlanView: View {
    let polygons: [[[Double]]]

    var body: some View {
        GeometryReader { geom in
            Canvas { ctx, size in
                guard !polygons.isEmpty else { return }
                // Compute shared bounds across polygons.
                var minX = Double.infinity, maxX = -Double.infinity
                var minY = Double.infinity, maxY = -Double.infinity
                for poly in polygons where poly.count >= 3 {
                    for p in poly where p.count >= 2 {
                        minX = Swift.min(minX, p[0]); maxX = Swift.max(maxX, p[0])
                        minY = Swift.min(minY, p[1]); maxY = Swift.max(maxY, p[1])
                    }
                }
                guard maxX > minX, maxY > minY else { return }

                let pad: CGFloat = 20
                let w = size.width - pad * 2
                let h = size.height - pad * 2
                let spanX = CGFloat(maxX - minX), spanY = CGFloat(maxY - minY)
                let scale = Swift.min(w / spanX, h / spanY)
                let offX = (size.width - spanX * scale) / 2
                let offY = (size.height - spanY * scale) / 2

                let accent = Color(red: 43/255, green: 79/255, blue: 224/255)
                let fill = accent.opacity(0.10)

                for poly in polygons where poly.count >= 3 {
                    var path = Path()
                    for (i, p) in poly.enumerated() where p.count >= 2 {
                        let x = CGFloat(p[0] - minX) * scale + offX
                        let y = CGFloat(p[1] - minY) * scale + offY
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    path.closeSubpath()
                    ctx.fill(path, with: .color(fill))
                    ctx.stroke(path, with: .color(accent), lineWidth: 1.5)
                }
            }
            .drawingGroup()
            .frame(width: geom.size.width, height: geom.size.height)
        }
        .background(Color(red: 232/255, green: 237/255, blue: 255/255))
    }
}
