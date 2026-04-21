import SwiftUI
import PhotosUI

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
    @State private var lightboxStart: Int?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var uploadingCount = 0
    @State private var deleteTarget: GalleryItem?
    @State private var error: String?

    private struct StartIndex: Identifiable { let value: Int; var id: Int { value } }

    private var lightboxPhotos: [LightboxPhoto] {
        items.compactMap { item in
            guard let afterString = item.imageURL, let afterURL = URL(string: afterString) else { return nil }
            let before = item.beforeImageURL.flatMap { URL(string: $0) }
            return LightboxPhoto(id: item.id, after: afterURL, before: before)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                if loading && items.isEmpty { ProgressView().tint(QTheme.primary) }
                else if items.isEmpty && uploadingCount == 0 {
                    VStack(spacing: 12) {
                        emptyState("Gallery is empty", "Tap the + button to add your first work photos.")
                        addPicker("Add photos")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            if uploadingCount > 0 {
                                uploadingTile
                            }
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                tile(item, index: idx)
                            }
                        }
                        .padding(12)

                        if let error, !error.isEmpty {
                            Text(error).font(.caption).foregroundStyle(QTheme.danger).padding(.horizontal, 16)
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose).foregroundStyle(QTheme.ink)
                }
                ToolbarItem(placement: .primaryAction) {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 6, matching: .images) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(QTheme.primary)
                    }
                    .accessibilityLabel("Add photos")
                }
            }
            .fullScreenCover(item: Binding(
                get: { lightboxStart.map { StartIndex(value: $0) } },
                set: { lightboxStart = $0?.value }
            )) { start in
                GalleryLightbox(
                    photos: lightboxPhotos,
                    startIndex: start.value,
                    onDismiss: { lightboxStart = nil }
                )
            }
            .alert(
                "Remove photo?",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                presenting: deleteTarget
            ) { target in
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    Task { await delete(target) }
                }
            } message: { _ in
                Text("This photo will no longer appear on your org profile.")
            }
            .onChange(of: pickerItems) { _, items in
                if !items.isEmpty { Task { await ingest(items) } }
            }
        }
        .tint(QTheme.primary)
        .task { await load() }
    }

    private var uploadingTile: some View {
        // Match the `aspectRatio(1, contentMode: .fit)` of the real tiles so
        // a mid-upload grid doesn't jitter as rows land.
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(QTheme.surfaceMuted)
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                VStack(spacing: 6) {
                    ProgressView().tint(QTheme.primary)
                    Text("Uploading…").font(.caption).foregroundStyle(QTheme.inkMuted)
                }
            )
    }

    private func tile(_ item: GalleryItem, index: Int) -> some View {
        // Uniform square so the grid reads as a clean 2-up no matter the
        // source aspect ratios. Tapping opens the paging lightbox at this
        // index; the trash badge is a separate hit area.
        ZStack(alignment: .topTrailing) {
            Color.clear.aspectRatio(1, contentMode: .fit)
            Group {
                if let urlString = item.imageURL, let url = URL(string: urlString) {
                    Button {
                        lightboxStart = index
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Rectangle().fill(QTheme.surfaceMuted)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()

                            if item.beforeImageURL != nil {
                                Text("BEFORE / AFTER")
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(0.4)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(Capsule())
                                    .padding(8)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    Rectangle().fill(QTheme.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            Button {
                deleteTarget = item
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .accessibilityLabel("Remove photo")
        }
    }

    private func addPicker(_ label: String) -> some View {
        PhotosPicker(selection: $pickerItems, maxSelectionCount: 6, matching: .images) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text(label)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(QTheme.primaryInk)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(QTheme.primary)
            .clipShape(Capsule())
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        items = (try? await OrgService.shared.listGallery()) ?? []
    }

    private func ingest(_ selected: [PhotosPickerItem]) async {
        defer { pickerItems = [] }
        for item in selected {
            uploadingCount += 1
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    uploadingCount -= 1
                    continue
                }
                let contentType = item.supportedContentTypes
                    .first(where: { $0.preferredMIMEType != nil })?
                    .preferredMIMEType ?? "image/jpeg"
                let slot = try await OrgService.shared.orgGalleryUploadURL(contentType: contentType)
                guard let url = URL(string: slot.uploadURL) else {
                    uploadingCount -= 1
                    continue
                }
                try await OrgService.shared.uploadBytes(to: url, contentType: contentType, data: data)
                try await OrgService.shared.addGalleryItem(imageBlobPath: slot.blobPath)
            } catch {
                self.error = error.localizedDescription
            }
            uploadingCount -= 1
        }
        await load()
    }

    private func delete(_ item: GalleryItem) async {
        do {
            try await OrgService.shared.deleteGalleryItem(imageId: item.id)
            items.removeAll { $0.id == item.id }
            deleteTarget = nil
        } catch { self.error = error.localizedDescription }
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
    @State private var allServices: [ServiceRecord] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var initialSelected: Set<String> = []

    private var hasChanges: Bool { selected != initialSelected }

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                if loading && allServices.isEmpty { ProgressView().tint(QTheme.primary) }
                else if allServices.isEmpty {
                    emptyState("No services available", "Pull to retry.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Pick the work categories your org covers. These power homeowner search.")
                                .font(.callout)
                                .foregroundStyle(QTheme.inkMuted)
                                .padding(.horizontal, 16)

                            LazyVStack(spacing: 0) {
                                ForEach(Array(allServices.enumerated()), id: \.element.id) { idx, s in
                                    if idx > 0 { Divider().background(QTheme.divider) }
                                    row(s)
                                }
                            }
                            .background(QTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(QTheme.hairline, lineWidth: 0.5))
                            .padding(.horizontal, 16)

                            if let error, !error.isEmpty {
                                Text(error).font(.caption).foregroundStyle(QTheme.danger)
                                    .padding(.horizontal, 16)
                            }
                        }
                        .padding(.vertical, 16)
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Services")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose).foregroundStyle(QTheme.ink)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: save) {
                        if saving { ProgressView().tint(QTheme.primary) }
                        else { Text("Save").font(.system(size: 15, weight: .semibold)).foregroundStyle(QTheme.primary) }
                    }
                    .disabled(saving || !hasChanges)
                }
            }
            .task { await load() }
        }
        .tint(QTheme.primary)
    }

    private func row(_ s: ServiceRecord) -> some View {
        Button {
            if selected.contains(s.id) { selected.remove(s.id) } else { selected.insert(s.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected.contains(s.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(selected.contains(s.id) ? QTheme.primary : QTheme.inkDim)
                Text(s.name)
                    .font(.system(size: 15))
                    .foregroundStyle(QTheme.ink)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let allTask = OrgService.shared.listAllServices()
            async let mineTask = OrgService.shared.listOrgServices()
            allServices = try await allTask
            let mine = (try? await mineTask) ?? []
            selected = Set(mine.map(\.id))
            initialSelected = selected
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        Task {
            saving = true
            defer { saving = false }
            do {
                try await OrgService.shared.updateOrgServices(serviceIds: Array(selected))
                initialSelected = selected
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: – Settings

struct OrgSettingsView: View {
    let onClose: () -> Void
    @State private var org: OrgProfile?
    @State private var name = ""
    @State private var description = ""
    @State private var address = ""
    @State private var websiteURL = ""
    @State private var yelpURL = ""
    @State private var googleReviewsURL = ""
    @State private var hours: [String: String] = [:]
    @State private var loading = true
    @State private var saving = false
    @State private var editing = false
    @State private var error: String?
    @State private var iconPicker: PhotosPickerItem?
    @State private var bannerPicker: PhotosPickerItem?
    @State private var uploadingIcon = false
    @State private var uploadingBanner = false

    private let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                if loading && org == nil { ProgressView().tint(QTheme.primary) }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            bannerCard
                            iconCard
                            infoSection
                            linksSection
                            hoursSection
                            if let error, !error.isEmpty {
                                Text(error).font(.caption).foregroundStyle(QTheme.danger)
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editing ? "Cancel" : "Close") {
                        if editing { resetFromOrg(); editing = false }
                        else { onClose() }
                    }
                    .foregroundStyle(QTheme.ink)
                }
                ToolbarItem(placement: .primaryAction) {
                    if editing {
                        Button(action: save) {
                            if saving { ProgressView().tint(QTheme.primary) }
                            else { Text("Save").font(.system(size: 15, weight: .semibold)).foregroundStyle(QTheme.primary) }
                        }
                        .disabled(saving || !hasChanges)
                    } else {
                        Button("Edit") { editing = true }
                            .fontWeight(.semibold)
                            .foregroundStyle(QTheme.primary)
                    }
                }
            }
            .task { await load() }
            .onChange(of: iconPicker) { _, item in
                if let item { Task { await uploadIcon(item) } }
            }
            .onChange(of: bannerPicker) { _, item in
                if let item { Task { await uploadBanner(item) } }
            }
        }
        .tint(QTheme.primary)
    }

    private var hasChanges: Bool {
        guard let org else { return false }
        return name != org.name
            || description != (org.description ?? "")
            || address != (org.address ?? "")
            || websiteURL != (org.websiteURL ?? "")
            || yelpURL != (org.yelpURL ?? "")
            || googleReviewsURL != (org.googleReviewsURL ?? "")
            || hours != (org.businessHours ?? [:])
    }

    // MARK: – Banner

    private var bannerCard: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let urlString = org?.bannerImageURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { QTheme.primary.opacity(0.5) }
                    }
                } else {
                    LinearGradient(colors: [QTheme.primary, QTheme.primarySoft], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if editing {
                PhotosPicker(selection: $bannerPicker, matching: .images) {
                    ZStack {
                        Circle().fill(.white).frame(width: 34, height: 34)
                        Image(systemName: uploadingBanner ? "arrow.up.circle.fill" : "camera.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(QTheme.ink)
                    }
                }
                .padding(10)
            }
        }
    }

    // MARK: – Icon

    private var iconCard: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let urlString = org?.iconURL, let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { iconInitials }
                        }
                    } else { iconInitials }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if editing {
                    PhotosPicker(selection: $iconPicker, matching: .images) {
                        ZStack {
                            Circle().fill(QTheme.primary).frame(width: 26, height: 26)
                            Image(systemName: uploadingIcon ? "arrow.up.circle.fill" : "camera.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(QTheme.primaryInk)
                        }
                    }
                    .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(name.isEmpty ? "Your Org" : name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(QTheme.ink)
                if uploadingIcon {
                    Text("Uploading…").font(.caption).foregroundStyle(QTheme.inkDim)
                }
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(QTheme.hairline, lineWidth: 0.5))
    }

    private var iconInitials: some View {
        let parts = (org?.name ?? "Q").split(separator: " ").prefix(2).compactMap { $0.first }
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(QTheme.primarySoft)
            .overlay(Text(String(parts)).font(.system(size: 22, weight: .bold)).foregroundStyle(QTheme.primary))
    }

    // MARK: – Info, links, hours

    private var infoSection: some View {
        settingsBlock(title: "About") {
            settingsField(label: "Organization name", text: $name, placeholder: "Your Org")
            settingsField(label: "Description", text: $description, placeholder: "Describe your services", multiline: true)
            settingsField(label: "Business address", text: $address, placeholder: "Street, City, State", multiline: true)
        }
    }

    private var linksSection: some View {
        settingsBlock(title: "Links") {
            settingsField(label: "Website", text: $websiteURL, placeholder: "https://…", keyboard: .URL)
            settingsField(label: "Yelp URL", text: $yelpURL, placeholder: "https://yelp.com/biz/…", keyboard: .URL)
            settingsField(label: "Google reviews URL", text: $googleReviewsURL, placeholder: "https://…", keyboard: .URL)
        }
    }

    private var hoursSection: some View {
        settingsBlock(title: "Business hours") {
            VStack(spacing: 8) {
                ForEach(days, id: \.self) { day in
                    HStack(spacing: 12) {
                        Text(day.capitalized)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(QTheme.ink)
                            .frame(width: 90, alignment: .leading)

                        TextField("Closed", text: Binding(
                            get: { hours[day] ?? "" },
                            set: { hours[day] = $0 }
                        ))
                        .disabled(!editing)
                        .font(.system(size: 14))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(QTheme.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func settingsBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold)).tracking(0.5)
                .foregroundStyle(QTheme.inkMuted)
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(QTheme.hairline, lineWidth: 0.5))
        }
    }

    private func settingsField(
        label: String,
        text: Binding<String>,
        placeholder: String,
        multiline: Bool = false,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        // Same container look in both modes; only the input reacts to
        // `editing`. Keeps the form from "jumping" visually when the user
        // toggles Edit and gives the read state a consistent field shape.
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(QTheme.inkSoft)
            Group {
                if multiline {
                    TextField(placeholder, text: text, axis: .vertical)
                        .lineLimit(1...6)
                } else {
                    TextField(placeholder, text: text)
                        .keyboardType(keyboard)
                        .autocapitalization(.none)
                }
            }
            .disabled(!editing)
            .font(.system(size: 16))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(QTheme.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: – Data

    private func load() async {
        do {
            let o = try await OrgService.shared.getOrg()
            org = o
            resetFromOrg()
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func resetFromOrg() {
        guard let o = org else { return }
        name = o.name
        description = o.description ?? ""
        address = o.address ?? ""
        websiteURL = o.websiteURL ?? ""
        yelpURL = o.yelpURL ?? ""
        googleReviewsURL = o.googleReviewsURL ?? ""
        hours = o.businessHours ?? [:]
    }

    private func save() {
        Task {
            saving = true
            defer { saving = false }
            do {
                try await OrgService.shared.updateOrg(fields: [
                    "name": name,
                    "description": description,
                    "address": address,
                    "website_url": websiteURL,
                    "yelp_url": yelpURL,
                    "google_reviews_url": googleReviewsURL,
                    "business_hours": hours,
                ])
                await load()
                editing = false
            } catch { self.error = error.localizedDescription }
        }
    }

    private func uploadIcon(_ item: PhotosPickerItem) async {
        uploadingIcon = true
        defer { uploadingIcon = false; iconPicker = nil }
        await uploadField(item: item, field: "icon_url", slotFetcher: OrgService.shared.orgIconUploadURL)
    }

    private func uploadBanner(_ item: PhotosPickerItem) async {
        uploadingBanner = true
        defer { uploadingBanner = false; bannerPicker = nil }
        // Banner reuses the gallery upload-url since there's no separate banner
        // endpoint — the gallery endpoint stores to the same org bucket.
        await uploadField(item: item, field: "banner_image_url", slotFetcher: OrgService.shared.orgGalleryUploadURL)
    }

    private func uploadField(
        item: PhotosPickerItem,
        field: String,
        slotFetcher: (String) async throws -> OrgService.UploadSlot
    ) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let contentType = item.supportedContentTypes
                .first(where: { $0.preferredMIMEType != nil })?
                .preferredMIMEType ?? "image/jpeg"
            let slot = try await slotFetcher(contentType)
            guard let url = URL(string: slot.uploadURL) else { return }
            try await OrgService.shared.uploadBytes(to: url, contentType: contentType, data: data)
            try await OrgService.shared.updateOrg(fields: [field: slot.blobPath])
            await load()
        } catch { self.error = error.localizedDescription }
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
