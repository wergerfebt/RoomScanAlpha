import SwiftUI

/// Homeowner-facing project detail. Opens from the RFQ list.
/// Matches the web `ProjectDetail` layout: header → scan band → scope → bids.
/// The big product shift is that bids now live on-device (previously web-only).
struct ProjectDetailView: View {
    let rfq: RFQ
    /// When set, shows a "Scan a room" toolbar button. Tapping it pops this
    /// view (via dismiss) and calls the closure so the parent can enter the
    /// scan flow with this RFQ selected.
    var onScanRoom: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var detail: ProjectDetail?
    @State private var bids: [Bid] = []
    @State private var loading = true
    @State private var error: String?
    @State private var hireConfirmation: Bid?
    @State private var hiring = false
    @State private var hiredError: String?
    @State private var scanView: ScanView = .floorplan
    @State private var interactingWithBEV = false
    @State private var bevFullscreen = false
    /// scan_id of the room currently highlighted. Nil until detail loads —
    /// we default to the first room on first appearance.
    @State private var selectedScanId: String?
    /// When true, show the RFQ-scoped inbox as a sheet.
    @State private var showMessages = false
    /// When true, show the project editor sheet.
    @State private var showEdit = false
    /// Route for "Message contractor X" — when set, presents the conversation sheet.
    @State private var conversationRoute: ConversationRoute?
    /// Bid-card "Message" buttons show a spinner while the POST is in flight.
    @State private var openingMessageForBidId: String?

    private struct ConversationRoute: Identifiable {
        let id: String
        let title: String
    }

    private enum ScanView: String { case floorplan, birdseye }

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
        if let room = selectedRoom {
            params += "&room=\(room.scanId)"
        }
        return URL(string: "\(embedBase)/embed/scan/\(rfq.id)?\(params)")
    }

    /// True when the selected room's cloud-side processing is done and a
    /// mesh is available for the embed viewer. Anything else is "processing".
    private var isSelectedRoomReady: Bool {
        switch selectedRoom?.scanStatus {
        case "complete", "completed": return true
        default: return false
        }
    }

    private var selectedRoomStatusLabel: String {
        switch selectedRoom?.scanStatus {
        case "failed": return "Processing failed"
        case .none: return "Processing"
        default: return "Processing"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let detail, !detail.rooms.isEmpty {
                    scanBand(detail: detail)
                }
                scopeSection
                ProjectMediaView(rfqId: rfq.id, canEdit: true)
                bidsSection
                rfqIdFooter
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 60)
        }
        .scrollDisabled(interactingWithBEV)
        .background(QTheme.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showEdit = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(QTheme.primary)
                }
                .accessibilityLabel("Edit project")

                Button {
                    showMessages = true
                } label: {
                    Image(systemName: "envelope")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(QTheme.primary)
                }
                .accessibilityLabel("Messages")

                if onScanRoom != nil {
                    Button {
                        onScanRoom?()
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Scan a room")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(QTheme.primary)
                    }
                }
            }
        }
        .sheet(isPresented: $showMessages) {
            InboxView(role: .homeowner, rfqFilter: rfq.id) {
                showMessages = false
            }
        }
        .sheet(isPresented: $showEdit) {
            EditProjectView(
                rfq: rfq,
                detail: detail,
                onSave: {
                    showEdit = false
                    Task { await load() }
                },
                onClose: { showEdit = false }
            )
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
        .fullScreenCover(isPresented: $bevFullscreen) {
            if let url = bevURL {
                BEVFullscreenView(url: url) { bevFullscreen = false }
            }
        }
    }

    // MARK: – Derived state

    private var scopeText: String? {
        if let s = detail?.projectScope, !s.isEmpty { return s }
        if let d = detail?.jobDescription, !d.isEmpty { return d }
        if let rd = rfq.description, !rd.isEmpty { return rd }
        return nil
    }

    /// Scope of the currently-selected room, or nil if the room has none.
    private var selectedRoomScope: RoomScopeSummary? {
        guard let items = selectedRoom?.scope?.items, !items.isEmpty else {
            if let notes = selectedRoom?.scope?.notes, !notes.isEmpty {
                return selectedRoom?.scope
            }
            return nil
        }
        return selectedRoom?.scope
    }

    private var hasAnyScope: Bool {
        (scopeText?.isEmpty == false) || selectedRoomScope != nil
    }

    private var sortedBids: [Bid] {
        bids.sorted { $0.priceCents < $1.priceCents }
    }

    private var lowestPriceCents: Int? {
        bids.map(\.priceCents).min()
    }

    // MARK: – Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rfq.displayTitle)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(QTheme.ink)
                .tracking(-0.8)

            if let description = rfq.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(QTheme.inkSoft)
                    .lineSpacing(2)
                    .padding(.top, 4)
            }

            HStack(spacing: 8) {
                if let address = rfq.address, !address.isEmpty {
                    metaChip(Image(systemName: "mappin.and.ellipse"), address)
                    if detail != nil { dot }
                }
                if let detail, !detail.rooms.isEmpty {
                    Text("\(detail.rooms.count) \(detail.rooms.count == 1 ? "room" : "rooms")")
                        .font(.subheadline)
                        .foregroundStyle(QTheme.inkMuted)
                    if let created = shortDate(rfq.createdAt) { dot; Text(created).font(.subheadline).foregroundStyle(QTheme.inkMuted) }
                } else if let created = shortDate(rfq.createdAt) {
                    Text(created).font(.subheadline).foregroundStyle(QTheme.inkMuted)
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: – Scan band

    private func scanBand(detail: ProjectDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Scan")
            VStack(alignment: .leading, spacing: 14) {
                // Tab toggle: Floor plan / Bird's eye
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
                        ProjectFloorPlanView(rooms: detail.rooms)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    case .birdseye:
                        if isSelectedRoomReady, let url = bevURL {
                            ZStack(alignment: .topTrailing) {
                                EmbedWebView(url: url)
                                    .background(Color.black)
                                    // Claim touches inside the BEV region so the outer
                                    // ScrollView doesn't scroll while the user is
                                    // panning/rotating the 3D scene. Minimum distance 0
                                    // flips the state on touch-down.
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { _ in
                                                if !interactingWithBEV { interactingWithBEV = true }
                                            }
                                            .onEnded { _ in interactingWithBEV = false }
                                    )

                                // Fullscreen toggle
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
                        } else {
                            processingPlaceholder
                        }
                    }
                }
                .onChange(of: scanView) { _, newValue in
                    if newValue != .birdseye { interactingWithBEV = false }
                }

                statsGrid(detail: detail)

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

    /// Shown in the Bird's-eye tab when the selected room's mesh isn't
    /// ready yet. The scan has uploaded successfully; the cloud processor
    /// is rebuilding the textured OBJ (~30-60s typical, longer for large
    /// rooms). Takes the same frame as the live BEV so the layout doesn't
    /// jump when processing finishes.
    private var processingPlaceholder: some View {
        let failed = selectedRoom?.scanStatus == "failed"
        return VStack(spacing: 12) {
            if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(QTheme.danger)
            } else {
                ProgressView().tint(QTheme.primary)
            }
            Text(selectedRoomStatusLabel)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(QTheme.ink)
            Text(failed
                 ? "This scan couldn't be processed. Try re-scanning the room."
                 : "Your 3D model is being built. This usually takes under a minute.")
                .font(.caption)
                .foregroundStyle(QTheme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(QTheme.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tabButton(_ label: String, active: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? QTheme.ink : QTheme.inkMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
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
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(isSelected ? QTheme.scanAccentSoft : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func statsGrid(detail: ProjectDetail) -> some View {
        // Stats reflect the selected room — matches the scope title and the
        // BEV viewport so the scan band is internally consistent.
        let room = selectedRoom
        let items: [(String, String, String)] = [
            ("Floor area", room?.floorAreaSqft.map(formattedNumber) ?? "—", "sqft"),
            ("Wall area", room?.wallAreaSqft.map(formattedNumber) ?? "—", "sqft"),
            ("Ceiling", room?.ceilingHeightFt.map { String(format: "%.1f", $0) } ?? "—", "ft"),
            ("Perimeter", room?.perimeterLinearFt.map(formattedNumber) ?? "—", "ft")
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
                .foregroundStyle(QTheme.inkMuted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(QTheme.ink)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(QTheme.inkMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(QTheme.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: QTheme.radiusMedium, style: .continuous))
    }

    // MARK: – Scope section

    @ViewBuilder
    private var scopeSection: some View {
        if hasAnyScope {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel(scopeTitle)
                VStack(alignment: .leading, spacing: 16) {
                    if let scopeText, !scopeText.isEmpty, selectedRoomScope == nil {
                        Text(scopeText)
                            .font(.system(size: 15))
                            .foregroundStyle(QTheme.ink)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let scope = selectedRoomScope {
                        VStack(alignment: .leading, spacing: 10) {
                            ChipFlowLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(scope.items ?? [], id: \.self) { item in
                                    scopeChip(formatScopeLabel(item))
                                }
                            }
                            if let note = scope.notes, !note.isEmpty {
                                Text(note)
                                    .font(.system(size: 13, design: .default))
                                    .foregroundStyle(QTheme.inkMuted)
                                    .italic()
                                    .padding(.top, 4)
                            }
                        }
                    } else if scopeText == nil || scopeText?.isEmpty == true {
                        Text("No scope items selected for \(selectedRoom?.displayLabel ?? "this room").")
                            .font(.callout)
                            .foregroundStyle(QTheme.inkMuted)
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

    private func scopeChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(QTheme.primarySoft)
            .foregroundStyle(QTheme.primary)
            .clipShape(Capsule())
    }

    // MARK: – Bids section

    private var bidsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Bids")
            if loading && bids.isEmpty {
                ProgressView()
                    .tint(QTheme.primary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else if bids.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No bids yet").font(.headline).foregroundStyle(QTheme.ink)
                    Text("Contractors submit quotes after reviewing your 3D scan. Most arrive within 48 hours.")
                        .font(.callout)
                        .foregroundStyle(QTheme.inkMuted)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: QTheme.radiusXLarge, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: QTheme.radiusXLarge, style: .continuous).strokeBorder(QTheme.hairline))
            } else {
                headlinePrice
                VStack(spacing: 12) {
                    ForEach(sortedBids) { bid in
                        bidCard(bid)
                    }
                }
            }
            if let error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(QTheme.danger)
            }
        }
    }

    private var headlinePrice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(bids.count) \(bids.count == 1 ? "bid" : "bids")")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(QTheme.ink)
            if let low = lowestPriceCents {
                Text("· low")
                    .foregroundStyle(QTheme.inkMuted)
                    .font(.system(size: 16))
                Text(priceString(low))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(QTheme.success)
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
                flag(text: "LOWEST BID", color: QTheme.primary)
            } else if accepted {
                flag(text: "HIRED", color: QTheme.success)
            }

            NavigationLink {
                OrgProfileView(orgId: bid.contractor.id) {
                    Task { await openConversation(with: bid) }
                }
            } label: {
                HStack(spacing: 12) {
                    contractorAvatar(bid.contractor).frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bid.contractor.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(QTheme.ink)
                        if let rating = bid.contractor.reviewRating {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill").foregroundStyle(QTheme.warning).font(.caption)
                                Text(String(format: "%.1f", rating)).font(.caption).fontWeight(.semibold).foregroundStyle(QTheme.inkSoft)
                                if let count = bid.contractor.reviewCount {
                                    Text("· \(count) reviews").font(.caption).foregroundStyle(QTheme.inkMuted)
                                }
                            }
                        } else {
                            Text("No reviews yet").font(.caption).foregroundStyle(QTheme.inkDim)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(QTheme.inkDim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(bid.displayPrice)
                .font(.system(size: 34, weight: .bold))
                .tracking(-1)
                .foregroundStyle(QTheme.ink)
                .monospacedDigit()

            if let submitted = shortDate(bid.receivedAt) {
                Text("Submitted \(submitted)")
                    .font(.caption)
                    .foregroundStyle(QTheme.inkMuted)
            }

            if !parsed.timeline.isEmpty || !parsed.start.isEmpty {
                HStack(spacing: 16) {
                    if !parsed.timeline.isEmpty { inlineMeta("TIMELINE", parsed.timeline) }
                    if !parsed.start.isEmpty { inlineMeta("START", parsed.start) }
                }
            }

            if !parsed.note.isEmpty {
                Text(parsed.note)
                    .font(.callout)
                    .foregroundStyle(QTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            if let pdf = bid.pdfURL, let url = URL(string: pdf) {
                Link(destination: url) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill").foregroundStyle(QTheme.danger)
                        Text("View project breakdown PDF")
                            .font(.callout)
                            .fontWeight(.semibold)
                            .foregroundStyle(QTheme.ink)
                        Spacer()
                        Image(systemName: "arrow.up.right.square").foregroundStyle(QTheme.inkMuted)
                    }
                    .padding(12)
                    .background(QTheme.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await openConversation(with: bid) }
                } label: {
                    HStack(spacing: 6) {
                        if openingMessageForBidId == bid.id {
                            ProgressView().tint(QTheme.primary).scaleEffect(0.8)
                        } else {
                            Image(systemName: "envelope").font(.system(size: 13, weight: .semibold))
                        }
                        Text("Message").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(QTheme.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.primary, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(openingMessageForBidId != nil)

                Button {
                    hireConfirmation = bid
                } label: {
                    Text(accepted ? "Hired" : "Hire")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(QTheme.primaryInk)
                        .background(accepted ? QTheme.success : QTheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(hiring || accepted || anyAccepted)
                .opacity((hiring || anyAccepted) && !accepted ? 0.4 : 1)
            }
        }
        .padding(18)
        .background(QTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    accepted ? QTheme.success : (isLowest ? QTheme.primary : QTheme.hairline),
                    lineWidth: (accepted || isLowest) ? 2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: – RFQ ID footer

    /// Dim ID line at the bottom of the page. Long-pressable to copy.
    private var rfqIdFooter: some View {
        HStack {
            Spacer()
            Button {
                UIPasteboard.general.string = rfq.id
            } label: {
                Text("RFQ ID · \(rfq.id)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(QTheme.inkDim)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.top, 24)
        .accessibilityHint("Tap to copy")
    }

    // MARK: – Small helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(QTheme.inkMuted)
    }

    private func metaChip(_ icon: Image, _ text: String) -> some View {
        HStack(spacing: 4) {
            icon.font(.caption)
            Text(text).font(.subheadline)
        }
        .foregroundStyle(QTheme.inkMuted)
    }

    private var dot: some View {
        Circle().fill(QTheme.inkDim).frame(width: 3, height: 3)
    }

    private func inlineMeta(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(QTheme.inkMuted)
            Text(value).font(.subheadline).fontWeight(.medium).foregroundStyle(QTheme.ink)
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
            .fill(QTheme.primarySoft)
            .overlay(Text(initials).font(.headline).foregroundStyle(QTheme.primary))
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
        async let detailTask = RFQService.shared.getProjectDetail(rfqId: rfq.id)
        async let bidsTask = RFQService.shared.getBids(rfqId: rfq.id)
        do {
            let (d, b) = try await (detailTask, bidsTask)
            detail = d
            bids = b
            if selectedScanId == nil, let first = d.rooms.first {
                selectedScanId = first.scanId
            }
        } catch {
            self.error = (error as NSError).localizedDescription
        }
        loading = false
    }

    /// Open (or create) a conversation with the contractor behind a bid.
    /// Used by the bid-card Message button and the OrgProfileView CTA.
    private func openConversation(with bid: Bid) async {
        openingMessageForBidId = bid.id
        defer { openingMessageForBidId = nil }
        do {
            let convId = try await InboxService.shared.createConversation(
                rfqId: rfq.id,
                orgId: bid.contractor.id
            )
            conversationRoute = ConversationRoute(
                id: convId,
                title: bid.contractor.displayName
            )
        } catch {
            self.hiredError = error.localizedDescription
        }
    }

    private func hire(bid: Bid) async {
        hiring = true
        hiredError = nil
        do {
            try await RFQService.shared.acceptBid(rfqId: rfq.id, bidId: bid.id)
            bids = (try? await RFQService.shared.getBids(rfqId: rfq.id)) ?? bids
        } catch {
            hiredError = (error as NSError).localizedDescription
        }
        hiring = false
    }
}

// MARK: – Fullscreen BEV cover

/// Fullscreen presentation of the embed viewer. Pure black background so the
/// 3D scene is the whole stage. A dismiss chip sits above the safe area.
private struct BEVFullscreenView: View {
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
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Close")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .background(Color.black.opacity(0.35))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.leading, 16)
            .accessibilityLabel("Exit full screen")
        }
        .statusBarHidden(true)
    }
}

// MARK: – Flow layout for scope chips (so they wrap to multiple lines)

/// Lightweight wrap layout. Lays out children left-to-right and wraps to
/// the next row when out of width. Keeps chip size consistent.
private struct ChipFlowLayout: Layout {
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
                rowWidth = 0
                rowHeight = 0
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

// MARK: – Floor plan with wall dimensions

/// Flat top-down polygon sketch with per-wall length labels.
/// Draws in the scan-accent indigo to stay consistent with the web viewer.
private struct ProjectFloorPlanView: View {
    let rooms: [ProjectRoom]

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
        // Lay rooms out horizontally with a gap, same as web FloorPlan.tsx.
        let gapFt: CGFloat = 3
        var placed: [(poly: [CGPoint], label: String)] = []
        var cursorX: CGFloat = 0
        for r in rooms {
            guard let poly = r.roomPolygonFt, poly.count >= 3 else { continue }
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity
            var minY = CGFloat.infinity
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
            placed.append((shifted, r.displayLabel))
            cursorX += (maxX - minX) + gapFt
        }
        guard !placed.isEmpty else { return }

        // Shared bounds.
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for (poly, _) in placed {
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
        let fill = accent.opacity(0.10)

        for (poly, label) in placed {
            var path = Path()
            for (i, p) in poly.enumerated() {
                let pt = CGPoint(x: tx(p.x), y: ty(p.y))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            path.closeSubpath()
            ctx.fill(path, with: .color(fill))
            ctx.stroke(path, with: .color(accent), lineWidth: 1.5)

            // Wall dimensions — label each edge with its length in feet.
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
                // Outward normal so labels sit off the wall rather than across it.
                let nx = -dy / len * 9
                let ny = dx / len * 9
                let pos = CGPoint(x: mid.x + nx, y: mid.y + ny)
                let text = Text(String(format: "%.1f'", wallFt))
                    .font(labelFont)
                    .foregroundColor(QTheme.inkSoft)
                ctx.draw(text, at: pos, anchor: .center)
            }

            // Room label — centroid.
            let sum = poly.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let centroid = CGPoint(x: sum.x / CGFloat(poly.count), y: sum.y / CGFloat(poly.count))
            let labelText = Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(QTheme.ink)
            ctx.draw(labelText, at: CGPoint(x: tx(centroid.x), y: ty(centroid.y)), anchor: .center)
        }
    }
}
