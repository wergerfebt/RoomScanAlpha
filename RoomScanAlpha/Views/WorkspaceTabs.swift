import SwiftUI

// MARK: – Jobs

/// Contractor jobs list — what bids the org has submitted, what's pending,
/// and recent incoming RFQs. Tapping a job navigates to the scan detail
/// (reusing the same ProjectDetailView the homeowner sees) so contractors
/// can review the room before bidding.
struct JobsView: View {
    let onClose: () -> Void

    @State private var jobs: [Job] = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter: Filter = .all

    private enum Filter: String, CaseIterable, Identifiable {
        case all, new, pending, won, lost
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    private var filtered: [Job] {
        filter == .all ? jobs : jobs.filter { $0.jobStatus == filter.rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                if loading && jobs.isEmpty {
                    ProgressView().tint(QTheme.primary)
                } else if filtered.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("Jobs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose).foregroundStyle(QTheme.ink)
                }
            }
        }
        .tint(QTheme.primary)
        .task { await load() }
        .refreshable { await load() }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        Text("\(f.label) \(count(for: f))").tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 4)

                LazyVStack(spacing: 10) {
                    ForEach(filtered) { job in
                        NavigationLink {
                            JobDetailView(job: job)
                        } label: {
                            jobRow(job)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "briefcase").font(.system(size: 34)).foregroundStyle(QTheme.inkDim)
            Text("No jobs yet").font(.system(size: 17, weight: .semibold)).foregroundStyle(QTheme.ink)
            Text("Jobs from homeowners appear here as they post projects matching your services.")
                .font(.subheadline).foregroundStyle(QTheme.inkMuted).multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func jobRow(_ job: Job) -> some View {
        let tint: Color = {
            switch job.jobStatus {
            case "won": return QTheme.primary
            case "pending": return QTheme.warning
            case "lost": return QTheme.inkMuted
            default: return QTheme.scanAccent // new
            }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(QTheme.ink)
                        .lineLimit(1)
                    if let desc = job.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 13))
                            .foregroundStyle(QTheme.inkSoft)
                            .lineLimit(2)
                    }
                    if let address = job.address, !address.isEmpty {
                        Text(address)
                            .font(.system(size: 12))
                            .foregroundStyle(QTheme.inkMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let cents = job.bid?.priceCents {
                    Text("$\(cents / 100)")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(QTheme.ink)
                        .monospacedDigit()
                }
            }
            HStack(spacing: 8) {
                Text(job.jobStatus.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(tint)
                    .background(tint.opacity(0.12))
                    .clipShape(Capsule())
                if job.rfqDeleted == true {
                    Text("CANCELLED")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(QTheme.danger)
                        .background(QTheme.danger.opacity(0.12))
                        .clipShape(Capsule())
                }
                if job.bid?.rfqModifiedAfterBid == true {
                    Text("PROJECT UPDATED")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(QTheme.warning)
                        .background(QTheme.warning.opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QTheme.surface)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(QTheme.hairline, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func count(for filter: Filter) -> String {
        let n = filter == .all ? jobs.count : jobs.filter { $0.jobStatus == filter.rawValue }.count
        return "(\(n))"
    }

    private func load() async {
        loading = true
        do { jobs = try await OrgService.shared.listJobs() }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

// MARK: – Gallery

struct OrgGalleryView: View {
    let onClose: () -> Void
    @State private var items: [GalleryItem] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                if loading { ProgressView().tint(QTheme.primary) }
                else if items.isEmpty {
                    emptyState("Gallery is empty", "Upload photos from the web dashboard at roomscanalpha.com.")
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(items) { item in
                                if let urlString = item.imageURL, let url = URL(string: urlString) {
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Rectangle().fill(QTheme.surfaceMuted)
                                        }
                                    }
                                    .frame(height: 140)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose).foregroundStyle(QTheme.ink)
                }
            }
        }
        .tint(QTheme.primary)
        .task {
            items = (try? await OrgService.shared.listGallery()) ?? []
            loading = false
        }
    }
}

// MARK: – Team

struct OrgTeamView: View {
    let onClose: () -> Void
    @State private var members: [OrgMember] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                if loading { ProgressView().tint(QTheme.primary) }
                else if members.isEmpty {
                    emptyState("No team members", "Invite people from the web dashboard.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(members.enumerated()), id: \.element.id) { idx, m in
                                if idx > 0 { Divider().background(QTheme.divider).padding(.leading, 60) }
                                memberRow(m)
                            }
                        }
                        .background(QTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(QTheme.hairline, lineWidth: 0.5))
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose).foregroundStyle(QTheme.ink)
                }
            }
        }
        .tint(QTheme.primary)
        .task {
            members = (try? await OrgService.shared.listMembers()) ?? []
            loading = false
        }
    }

    private func memberRow(_ m: OrgMember) -> some View {
        HStack(spacing: 12) {
            avatar(m).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name ?? m.email)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(QTheme.ink)
                Text(m.email)
                    .font(.system(size: 13))
                    .foregroundStyle(QTheme.inkMuted)
                    .lineLimit(1)
            }
            Spacer()
            Text(m.role.capitalized)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.3)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(QTheme.primary)
                .background(QTheme.primarySoft)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder
    private func avatar(_ m: OrgMember) -> some View {
        if let urlString = m.iconURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { initialsTile(m.name ?? m.email) }
            }
            .clipShape(Circle())
        } else {
            initialsTile(m.name ?? m.email)
        }
    }

    private func initialsTile(_ name: String) -> some View {
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return Circle()
            .fill(QTheme.primarySoft)
            .overlay(Text(String(parts).uppercased()).font(.system(size: 13, weight: .bold)).foregroundStyle(QTheme.primary))
    }
}

// MARK: – Services

struct OrgServicesView: View {
    let onClose: () -> Void
    @State private var services: [OrgProfile.Service] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                if loading { ProgressView().tint(QTheme.primary) }
                else if services.isEmpty {
                    emptyState("No services selected", "Pick your service categories from the web dashboard.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(services.enumerated()), id: \.element.id) { idx, s in
                                if idx > 0 { Divider().background(QTheme.divider) }
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(QTheme.primary)
                                    Text(s.name)
                                        .font(.system(size: 15))
                                        .foregroundStyle(QTheme.ink)
                                    Spacer()
                                }
                                .padding(14)
                            }
                        }
                        .background(QTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(QTheme.hairline, lineWidth: 0.5))
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Services")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose).foregroundStyle(QTheme.ink)
                }
            }
        }
        .tint(QTheme.primary)
        .task {
            services = (try? await OrgService.shared.listOrgServices()) ?? []
            loading = false
        }
    }
}

// MARK: – Settings

struct OrgSettingsView: View {
    let onClose: () -> Void
    @State private var org: OrgProfile?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                if loading { ProgressView().tint(QTheme.primary) }
                else if let org = org {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            infoRow(label: "Organization", value: org.name)
                            if let description = org.description, !description.isEmpty {
                                infoRow(label: "Description", value: description)
                            }
                            if let address = org.address, !address.isEmpty {
                                infoRow(label: "Address", value: address)
                            }
                            if let rating = org.avgRating {
                                infoRow(label: "Rating", value: String(format: "%.1f", rating))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("PROFILE EDITING")
                                    .font(.system(size: 11, weight: .bold))
                                    .tracking(0.5)
                                    .foregroundStyle(QTheme.inkMuted)
                                Text("To edit your logo, banner, hours, or services, sign in at roomscanalpha.com on the web.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(QTheme.inkSoft)
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(QTheme.surfaceMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .padding(20)
                    }
                } else {
                    emptyState("Couldn't load settings", "Check your connection and retry.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose).foregroundStyle(QTheme.ink)
                }
            }
        }
        .tint(QTheme.primary)
        .task {
            org = try? await OrgService.shared.getOrg()
            loading = false
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(QTheme.inkMuted)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(QTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(QTheme.hairline, lineWidth: 0.5))
    }
}

// MARK: – Shared empty state

@ViewBuilder
private func emptyState(_ title: String, _ subtitle: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: "tray").font(.system(size: 32)).foregroundStyle(QTheme.inkDim)
        Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(QTheme.ink)
        Text(subtitle).font(.subheadline).foregroundStyle(QTheme.inkMuted).multilineTextAlignment(.center)
    }
    .padding(32)
}
