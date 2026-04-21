import SwiftUI

/// Project picker for the scan flow. Doubles as the user's Projects list —
/// tap a card body to select for the current scan, or tap ⓘ to open the
/// full Project Detail with bids.
struct RFQSelectionView: View {
    @Binding var selectedRFQ: RFQ?
    @State private var rfqs: [RFQ] = []
    @State private var isLoading = true
    @State private var showNewProject = false
    @State private var errorMessage: String?
    @State private var filter: Filter = .all

    private enum Filter: String, CaseIterable, Identifiable {
        case all, awaiting, hired
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .awaiting: return "Awaiting bids"
            case .hired: return "Hired"
            }
        }
    }

    private var filtered: [RFQ] {
        switch filter {
        case .all: return rfqs
        case .awaiting: return rfqs.filter { ($0.bidCount ?? 0) == 0 && $0.status != "completed" }
        case .hired: return rfqs.filter { $0.status == "completed" }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()

                if isLoading {
                    ProgressView("Loading projects…")
                        .tint(QTheme.primary)
                } else if rfqs.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewProject = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(QTheme.ink)
                    }
                }
            }
            .sheet(isPresented: $showNewProject) {
                NewProjectSheet { title, description, address in
                    showNewProject = false
                    createRFQ(title: title, description: description, address: address)
                }
            }
            .task { await loadRFQs() }
        }
        .tint(QTheme.primary)
    }

    // MARK: – Content

    private var content: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Segmented control
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 4)

                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Text(emptyFilterTitle)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(QTheme.ink)
                        Text("Switch filter or create a new project.")
                            .font(.subheadline)
                            .foregroundStyle(QTheme.inkMuted)
                    }
                    .padding(40)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { rfq in
                            projectCard(rfq)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
            }
        }
    }

    private var emptyFilterTitle: String {
        switch filter {
        case .all: return "No projects"
        case .awaiting: return "No projects awaiting bids"
        case .hired: return "No hired projects yet"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(QTheme.inkDim)
            Text("No projects yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(QTheme.ink)
            Text("Create a project to start scanning.")
                .font(.subheadline)
                .foregroundStyle(QTheme.inkMuted)
                .multilineTextAlignment(.center)
            Button {
                showNewProject = true
            } label: {
                Text("New project")
                    .font(.headline)
                    .foregroundStyle(QTheme.primaryInk)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(QTheme.primary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(32)
    }

    private func projectCard(_ rfq: RFQ) -> some View {
        let nBids = rfq.bidCount ?? 0
        let hired = rfq.status == "completed"
        let bidLabel: String
        if hired { bidLabel = "Hired" }
        else if nBids == 0 { bidLabel = "Awaiting bids" }
        else if nBids == 1 { bidLabel = "1 bid" }
        else { bidLabel = "\(nBids) bids" }
        let bidColor: Color = hired ? QTheme.primary : (nBids == 0 ? QTheme.warning : QTheme.success)
        let bidBg: Color = hired ? QTheme.primarySoft : (nBids == 0 ? QTheme.warning.opacity(0.12) : QTheme.success.opacity(0.12))
        let selected = selectedRFQ?.id == rfq.id

        return HStack(alignment: .top, spacing: 10) {
            Button {
                selectedRFQ = rfq
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(rfq.displayTitle)
                                    .font(.system(size: 17, weight: .bold))
                                    .tracking(-0.3)
                                    .foregroundStyle(QTheme.ink)
                                    .lineLimit(1)
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(QTheme.primary)
                                        .font(.system(size: 14))
                                }
                            }
                            if let address = rfq.address, !address.isEmpty {
                                Text(address)
                                    .font(.system(size: 13))
                                    .foregroundStyle(QTheme.inkMuted)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(bidLabel)
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(bidColor)
                            .background(bidBg)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    Rectangle()
                        .fill(QTheme.divider)
                        .frame(height: 0.5)

                    HStack(spacing: 10) {
                        Label {
                            Text(roomsLabel(rfq))
                                .font(.system(size: 13))
                                .foregroundStyle(QTheme.inkMuted)
                        } icon: {
                            Image(systemName: "house")
                                .font(.system(size: 12))
                                .foregroundStyle(QTheme.inkMuted)
                        }
                        .labelStyle(.titleAndIcon)

                        if let created = shortDate(rfq.createdAt) {
                            dot
                            Text("Created \(created)")
                                .font(.system(size: 13))
                                .foregroundStyle(QTheme.inkMuted)
                        }

                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(selected ? QTheme.primary.opacity(0.5) : QTheme.hairline, lineWidth: selected ? 1.5 : 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink {
                ProjectDetailView(rfq: rfq)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(QTheme.inkMuted)
                    .padding(.vertical, 24)
                    .padding(.horizontal, 8)
                    .background(QTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(QTheme.hairline, lineWidth: 0.5)
                    )
                    .accessibilityLabel("Open \(rfq.displayTitle) details")
            }
            .buttonStyle(.plain)
        }
    }

    private var dot: some View {
        Circle().fill(QTheme.inkDim).frame(width: 3, height: 3)
    }

    private func roomsLabel(_ rfq: RFQ) -> String {
        guard let count = rfq.scanCount, count > 0 else { return "Ready to scan" }
        return "\(count) \(count == 1 ? "room" : "rooms")"
    }

    private func shortDate(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: date)
    }

    // MARK: – Data

    private func loadRFQs() async {
        isLoading = true
        do {
            rfqs = try await RFQService.shared.listRFQs()
        } catch {
            errorMessage = error.localizedDescription
            print("[RoomScanAlpha] Failed to load RFQs: \(error)")
        }
        isLoading = false
    }

    private func createRFQ(title: String, description: String, address: String) {
        Task {
            do {
                let rfq = try await RFQService.shared.createRFQ(
                    title: title,
                    description: description,
                    address: address.isEmpty ? nil : address
                )
                rfqs.insert(rfq, at: 0)
                selectedRFQ = rfq
            } catch {
                errorMessage = error.localizedDescription
                print("[RoomScanAlpha] Failed to create RFQ: \(error)")
            }
        }
    }
}
