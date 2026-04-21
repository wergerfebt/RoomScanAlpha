import SwiftUI

/// Public contractor org profile — matches the mobile-web `/contractors/:orgId`
/// experience: banner, name/rating header, description, services, gallery,
/// links to Yelp/Google reviews.
struct OrgProfileView: View {
    let orgId: String
    /// Optional "Message" callback — when provided, a CTA button sits under
    /// the header so homeowners can start a conversation with this org.
    var onMessage: (() -> Void)? = nil

    @State private var org: OrgProfile?
    @State private var loading = true
    @State private var error: String?
    @State private var lightboxStart: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let org = org {
                    banner(org)
                    VStack(alignment: .leading, spacing: 24) {
                        header(org)
                        if onMessage != nil {
                            messageButton
                        }
                        if let description = org.description, !description.isEmpty {
                            aboutBlock(description)
                        }
                        if let services = org.services, !services.isEmpty {
                            servicesBlock(services)
                        }
                        if let gallery = org.gallery, !gallery.isEmpty {
                            galleryBlock(gallery)
                        }
                        if let hours = org.businessHours, !hours.isEmpty {
                            hoursBlock(hours)
                        }
                        linksBlock(org)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                } else if loading {
                    ProgressView().tint(QTheme.primary).frame(maxWidth: .infinity).padding(.top, 80)
                } else if let error = error {
                    VStack(spacing: 8) {
                        Text("Couldn't load profile").font(.system(size: 17, weight: .semibold))
                        Text(error).font(.subheadline).foregroundStyle(QTheme.inkMuted)
                    }
                    .padding(40)
                }
            }
        }
        .background(QTheme.canvas.ignoresSafeArea())
        .navigationTitle(org?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
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
    }

    private struct StartIndex: Identifiable { let value: Int; var id: Int { value } }

    private var lightboxPhotos: [LightboxPhoto] {
        (org?.gallery ?? []).compactMap { img in
            guard let afterString = img.imageURL, let afterURL = URL(string: afterString) else { return nil }
            let before = img.beforeImageURL.flatMap { URL(string: $0) }
            return LightboxPhoto(id: img.id, after: afterURL, before: before)
        }
    }

    private var messageButton: some View {
        Button {
            onMessage?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "envelope.fill").font(.system(size: 15, weight: .semibold))
                Text("Message").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(QTheme.primaryInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(QTheme.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: – Sections

    private func banner(_ org: OrgProfile) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let urlString = org.bannerImageURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        QTheme.primary
                    }
                }
            } else {
                QTheme.primary
            }
        }
        .frame(height: 160)
        .clipped()
    }

    private func header(_ org: OrgProfile) -> some View {
        HStack(alignment: .center, spacing: 14) {
            avatar(org).frame(width: 72, height: 72)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(QTheme.surface, lineWidth: 4))
                .offset(y: -36)
            VStack(alignment: .leading, spacing: 4) {
                Text(org.name)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(QTheme.ink)
                HStack(spacing: 8) {
                    if let rating = org.avgRating {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").foregroundStyle(QTheme.warning).font(.caption)
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(QTheme.inkSoft)
                        }
                    }
                    if let address = org.address, !address.isEmpty {
                        Text("·").foregroundStyle(QTheme.inkDim)
                        Text(address)
                            .font(.system(size: 13))
                            .foregroundStyle(QTheme.inkMuted)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, -28) // pull content up to avoid the negative avatar offset gap
    }

    @ViewBuilder
    private func avatar(_ org: OrgProfile) -> some View {
        if let urlString = org.iconURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initialsTile(org.name)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            initialsTile(org.name)
        }
    }

    private func initialsTile(_ name: String) -> some View {
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first }
        let initials = String(parts).uppercased()
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(QTheme.primarySoft)
            .overlay(Text(initials).font(.system(size: 22, weight: .bold)).foregroundStyle(QTheme.primary))
    }

    private func aboutBlock(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("About")
            Text(description)
                .font(.system(size: 15))
                .foregroundStyle(QTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(QTheme.hairline, lineWidth: 0.5))
        }
    }

    private func servicesBlock(_ services: [OrgProfile.Service]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Services")
            ChipFlow(spacing: 6) {
                ForEach(services) { service in
                    Text(service.name)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(QTheme.primarySoft)
                        .foregroundStyle(QTheme.primary)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func galleryBlock(_ gallery: [OrgProfile.GalleryImage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Work")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(gallery.enumerated()), id: \.element.id) { idx, img in
                        galleryTile(img)
                            .onTapGesture { lightboxStart = idx }
                    }
                }
            }
        }
    }

    /// Uniform square tile — keeps the horizontal scroller tidy even when
    /// source images vary wildly in aspect ratio. A before/after badge
    /// hints the pair is interactive.
    @ViewBuilder
    private func galleryTile(_ img: OrgProfile.GalleryImage) -> some View {
        if let urlString = img.imageURL, let url = URL(string: urlString) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(QTheme.surfaceMuted)
                    }
                }
                .frame(width: 160, height: 160)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if img.beforeImageURL != nil {
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
        }
    }

    private func hoursBlock(_ hours: [String: String]) -> some View {
        let order = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Hours")
            VStack(spacing: 0) {
                ForEach(Array(order.enumerated()), id: \.element) { idx, day in
                    if idx > 0 { Divider().background(QTheme.divider) }
                    HStack {
                        Text(day.capitalized)
                            .font(.system(size: 14))
                            .foregroundStyle(QTheme.inkSoft)
                        Spacer()
                        Text(hours[day]?.isEmpty == false ? hours[day]! : "Closed")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(hours[day]?.isEmpty == false ? QTheme.ink : QTheme.inkMuted)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                }
            }
            .background(QTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(QTheme.hairline, lineWidth: 0.5))
        }
    }

    private func linksBlock(_ org: OrgProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if org.websiteURL != nil || org.yelpURL != nil || org.googleReviewsURL != nil {
                sectionLabel("Links")
                VStack(spacing: 8) {
                    if let w = org.websiteURL, let url = URL(string: w) { linkRow("Website", icon: "globe", url: url) }
                    if let y = org.yelpURL, let url = URL(string: y) { linkRow("Yelp reviews", icon: "star.bubble", url: url) }
                    if let g = org.googleReviewsURL, let url = URL(string: g) { linkRow("Google reviews", icon: "star.circle", url: url) }
                }
            }
        }
    }

    private func linkRow(_ label: String, icon: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Image(systemName: icon).foregroundStyle(QTheme.primary).font(.system(size: 16))
                Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(QTheme.ink)
                Spacer()
                Image(systemName: "arrow.up.right.square").foregroundStyle(QTheme.inkMuted)
            }
            .padding(14)
            .background(QTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(QTheme.inkMuted)
    }

    private func load() async {
        loading = true
        do { org = try await ContractorsService.shared.getOrg(id: orgId) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

private struct LightboxItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// One photo in the lightbox — an after shot with an optional "before"
/// companion. When `before` is non-nil the lightbox renders a BEFORE/AFTER
/// toggle at the top so the user can flip between the two.
struct LightboxPhoto: Identifiable, Equatable {
    let id: String
    let after: URL
    let before: URL?

    init(id: String = UUID().uuidString, after: URL, before: URL? = nil) {
        self.id = id
        self.after = after
        self.before = before
    }
}

/// Fullscreen image viewer with pinch-to-zoom, left/right swipe paging,
/// and a BEFORE/AFTER toggle for photos that have a `before` URL.
///
/// Compat initializer: the single-URL version still exists so existing
/// callers (ProjectDetail photo strip, JobDetail media, etc.) don't need
/// to change.
struct GalleryLightbox: View {
    let photos: [LightboxPhoto]
    let startIndex: Int
    let onDismiss: () -> Void

    @State private var index: Int
    @State private var showBefore = false

    init(photos: [LightboxPhoto], startIndex: Int, onDismiss: @escaping () -> Void) {
        self.photos = photos
        self.startIndex = startIndex
        self.onDismiss = onDismiss
        _index = State(initialValue: max(0, min(startIndex, max(0, photos.count - 1))))
    }

    /// Legacy single-URL init used throughout the app.
    init(url: URL, onDismiss: @escaping () -> Void) {
        self.init(photos: [LightboxPhoto(after: url)], startIndex: 0, onDismiss: onDismiss)
    }

    private var currentPhoto: LightboxPhoto? {
        photos.indices.contains(index) ? photos[index] : nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.offset) { i, photo in
                    LightboxPage(
                        photo: photo,
                        showBefore: Binding(
                            get: { i == index && showBefore },
                            set: { showBefore = $0 }
                        )
                    )
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
            .ignoresSafeArea()
            .onChange(of: index) { _, _ in
                // Reset to AFTER when switching photos so before/after state
                // doesn't leak across pages.
                showBefore = false
            }

            HStack {
                Button(action: onDismiss) {
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
                Spacer()
                if photos.count > 1 {
                    Text("\(index + 1) / \(photos.count)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if currentPhoto?.before != nil {
                VStack {
                    Spacer()
                    HStack(spacing: 2) {
                        beforeAfterTab("Before", active: showBefore) { showBefore = true }
                        beforeAfterTab("After", active: !showBefore) { showBefore = false }
                    }
                    .padding(3)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(.bottom, 30)
                }
            }
        }
        .statusBarHidden(true)
    }

    private func beforeAfterTab(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? QTheme.ink : .white)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(active ? .white : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// One page inside the paging lightbox. Each page owns its own
/// zoom state so swiping doesn't clear the current page's zoom.
private struct LightboxPage: View {
    let photo: LightboxPhoto
    @Binding var showBefore: Bool

    @State private var scale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1

    private var displayedURL: URL {
        (showBefore ? photo.before : nil) ?? photo.after
    }

    var body: some View {
        AsyncImage(url: displayedURL) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale * gestureScale)
                    .gesture(
                        MagnificationGesture()
                            .updating($gestureScale) { value, state, _ in state = value }
                            .onEnded { value in
                                scale = max(1, min(scale * value, 4))
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { scale = scale > 1 ? 1 : 2 }
                    }
            } else if phase.error != nil {
                Image(systemName: "photo").font(.system(size: 48)).foregroundStyle(.white.opacity(0.6))
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: showBefore) { _, _ in
            // Reset zoom when flipping before/after so the user isn't
            // disoriented by a zoomed-in before shot.
            scale = 1
        }
    }
}

/// Lightweight wrap-flow used for chips. Named distinct from
/// ProjectDetailView's ChipFlowLayout to avoid symbol collisions.
private struct ChipFlow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 6, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        _ChipFlowLayout(spacing: spacing) {
            content
        }
    }
}

private struct _ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, totalW: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += rowH + spacing
                totalW = max(totalW, x - spacing)
                x = 0; rowH = 0
            }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: max(totalW, x - spacing), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
