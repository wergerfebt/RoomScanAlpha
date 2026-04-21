import SwiftUI

/// Public contractor org profile — matches the mobile-web `/contractors/:orgId`
/// experience: banner, name/rating header, description, services, gallery,
/// links to Yelp/Google reviews.
struct OrgProfileView: View {
    let orgId: String

    @State private var org: OrgProfile?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let org = org {
                    banner(org)
                    VStack(alignment: .leading, spacing: 24) {
                        header(org)
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
                    ForEach(gallery) { img in
                        if let urlString = img.imageURL, let url = URL(string: urlString) {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Rectangle().fill(QTheme.surfaceMuted)
                                }
                            }
                            .frame(width: 200, height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
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
