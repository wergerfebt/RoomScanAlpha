import SwiftUI

/// Contractor search — mirrors the mobile-web `/search` experience.
/// Service picker + location + result cards. Tapping a card pushes into
/// the public org profile.
struct SearchView: View {
    let onClose: () -> Void

    @State private var service: String = ""
    @State private var location: String = ""
    @State private var query: String = ""
    @State private var results: [ContractorSearchResult] = []
    @State private var loading = false
    @State private var error: String?
    /// True after the user has run their first search. Empty state text
    /// changes to reflect "try a different search" vs the initial prompt.
    @State private var hasSearched = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()

                VStack(spacing: 12) {
                    searchBar
                    servicePicker
                    resultsList
                }
                .padding(.top, 8)
            }
            .navigationTitle("Find a contractor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose)
                        .foregroundStyle(QTheme.ink)
                }
            }
        }
        .tint(QTheme.primary)
    }

    // MARK: – Fields

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(QTheme.inkMuted)
                    TextField("What do you need?", text: $query)
                        .focused($queryFocused)
                        .submitLabel(.search)
                        .onSubmit { Task { await runSearch() } }
                        .foregroundStyle(QTheme.ink)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().frame(height: 20)

                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(QTheme.inkMuted)
                    TextField("Zip code or city", text: $location)
                        .submitLabel(.search)
                        .onSubmit { Task { await runSearch() } }
                        .foregroundStyle(QTheme.ink)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Button {
                    Task { await runSearch() }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(QTheme.primaryInk)
                        .frame(width: 44, height: 44)
                        .background(QTheme.primary)
                }
                .buttonStyle(.plain)
            }
            .background(QTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(QTheme.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private var servicePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                servicePill("All", active: service.isEmpty) { service = "" }
                ForEach(ServiceCategory.all, id: \.self) { s in
                    servicePill(s, active: service == s) {
                        service = (service == s) ? "" : s
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func servicePill(_ label: String, active: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? QTheme.primaryInk : QTheme.inkSoft)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(active ? QTheme.primary : QTheme.surface)
                .overlay(
                    Capsule().strokeBorder(active ? .clear : QTheme.hairline, lineWidth: 0.5)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: – Results

    @ViewBuilder
    private var resultsList: some View {
        if loading {
            ProgressView()
                .tint(QTheme.primary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if let error = error {
            VStack(spacing: 8) {
                Text("Couldn't search").font(.system(size: 17, weight: .semibold))
                Text(error).font(.subheadline).foregroundStyle(QTheme.inkMuted)
            }
            .padding(32)
        } else if results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(QTheme.inkDim)
                Text(hasSearched ? "No contractors found" : "Find a contractor")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(QTheme.ink)
                Text(hasSearched
                     ? "Try a different service or location."
                     : "Pick a service, enter a zip or city, and tap search.")
                    .font(.subheadline)
                    .foregroundStyle(QTheme.inkMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(results) { result in
                        NavigationLink {
                            OrgProfileView(orgId: result.id)
                        } label: {
                            resultRow(result)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private func resultRow(_ r: ContractorSearchResult) -> some View {
        HStack(spacing: 12) {
            contractorAvatar(r)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(r.displayName)
                    .font(.system(size: 16, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(QTheme.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let rating = r.avgRating {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill").foregroundStyle(QTheme.warning)
                                .font(.system(size: 10))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(QTheme.inkSoft)
                        }
                        if let reviews = r.reviewCount {
                            Text("· \(reviews)")
                                .font(.system(size: 12))
                                .foregroundStyle(QTheme.inkMuted)
                        }
                    } else {
                        Text("No reviews yet")
                            .font(.system(size: 12))
                            .foregroundStyle(QTheme.inkDim)
                    }
                }
                if let address = r.address, !address.isEmpty {
                    Text(address)
                        .font(.system(size: 12))
                        .foregroundStyle(QTheme.inkMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(QTheme.inkDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(QTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(QTheme.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func contractorAvatar(_ r: ContractorSearchResult) -> some View {
        if let iconURL = r.iconURL, let url = URL(string: iconURL) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initialsAvatar(r.initials)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            initialsAvatar(r.initials)
        }
    }

    private func initialsAvatar(_ initials: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(QTheme.primarySoft)
            .overlay(Text(initials).font(.system(size: 14, weight: .bold)).foregroundStyle(QTheme.primary))
    }

    // MARK: – Data

    private func runSearch() async {
        loading = true
        error = nil
        hasSearched = true
        do {
            results = try await ContractorsService.shared.search(
                service: service.isEmpty ? nil : service,
                location: location.isEmpty ? nil : location,
                query: query.isEmpty ? nil : query
            )
        } catch {
            self.error = (error as NSError).localizedDescription
        }
        loading = false
    }
}
