import SwiftUI

/// Contractor workspace home — the dark counterpart to HomeView. Only shown
/// when the caller is a member of an org AND has tapped "Workspace" on the
/// personal home menu. Carries its own avatar menu with "Personal · Switch
/// back" to return to homeowner mode.
///
/// Layout: dark ink→forest gradient background, overview stats card, and a
/// 3×2 grid of workspace destinations (Inbox, Jobs, Gallery, Team, Services,
/// Settings).
struct ContractorHomeView: View {
    let org: Account.OrgMembership
    let onSwitchToPersonal: () -> Void
    let onOpenInbox: () -> Void
    let onOpenJobs: () -> Void
    let onOpenGallery: () -> Void
    let onOpenTeam: () -> Void
    let onOpenServices: () -> Void
    let onOpenSettings: () -> Void
    let onSignOut: () -> Void

    @State private var unreadInbox: Int = 0
    @State private var newJobs: Int = 0
    @State private var jobsCount: Int = 0
    @State private var loading = true
    @State private var signOutConfirm = false

    var body: some View {
        ZStack {
            backgroundGradient
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    overviewCard
                    destinationGrid
                    Spacer(minLength: 24)
                }
                .padding(.bottom, 40)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Sign out?", isPresented: $signOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive, action: onSignOut)
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: – Background

    /// Ink → forest radial, same tone as the Capture card on Home but
    /// expanded to fill the whole screen.
    private var backgroundGradient: some View {
        ZStack {
            QTheme.ink
            RadialGradient(
                colors: [QTheme.primary.opacity(0.55), .clear],
                center: UnitPoint(x: 0.85, y: 0.0),
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }

    // MARK: – Header (org icon + Personal · Switch back menu)

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // Left: small "Acting as" chip with org icon + name.
            HStack(spacing: 10) {
                orgAvatar
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("ACTING AS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(org.name)
                        .font(.system(size: 15, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }

            Spacer()

            iconButton(systemImage: "envelope", label: "Inbox", action: onOpenInbox)

            Menu {
                Button {
                    onSwitchToPersonal()
                } label: {
                    Label("Personal · Switch back", systemImage: "person.crop.circle")
                }
                Divider()
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    signOutConfirm = true
                }
            } label: {
                orgAvatar
                    .frame(width: 34, height: 34)
                    .accessibilityLabel("Account")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var orgAvatar: some View {
        if let urlString = org.iconURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    orgInitials
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            orgInitials
        }
    }

    private var orgInitials: some View {
        let parts = org.name.split(separator: " ").prefix(2).compactMap { $0.first }
        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(QTheme.primary)
            .overlay(Text(String(parts).uppercased()).font(.system(size: 13, weight: .bold)).foregroundStyle(QTheme.primaryInk))
    }

    private func iconButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.09))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .clipShape(Circle())
                .accessibilityLabel(label)
        }
        .buttonStyle(.plain)
    }

    // MARK: – Overview card

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("OVERVIEW")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))

            (
                Text("\(newJobs) new ").foregroundStyle(.white) +
                Text(newJobs == 1 ? "job" : "jobs").foregroundStyle(.white) +
                Text("\n\(unreadInbox) unread messages").foregroundStyle(.white.opacity(0.6))
            )
            .font(.system(size: 30, weight: .bold))
            .tracking(-0.6)
            .lineSpacing(2)

            HStack(spacing: 10) {
                Button(action: onOpenInbox) {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope.fill").font(.system(size: 14, weight: .semibold))
                        Text("Open inbox").font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.white)
                    .foregroundStyle(QTheme.ink)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(unreadInbox > 0 ? 1 : 0.85)

                Button(action: onOpenJobs) {
                    Text("Review jobs")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 20)
    }

    // MARK: – Destinations

    private var destinationGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WORKSPACE")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 24)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                destinationCard(label: "Inbox", systemImage: "envelope", badge: unreadInbox, action: onOpenInbox)
                destinationCard(label: "Jobs", systemImage: "briefcase", badge: newJobs, action: onOpenJobs)
                destinationCard(label: "Gallery", systemImage: "photo.on.rectangle", badge: 0, action: onOpenGallery)
                destinationCard(label: "Team", systemImage: "person.2", badge: 0, action: onOpenTeam)
                destinationCard(label: "Services", systemImage: "wrench.and.screwdriver", badge: 0, action: onOpenServices)
                destinationCard(label: "Settings", systemImage: "gearshape", badge: 0, action: onOpenSettings)
            }
            .padding(.horizontal, 20)
        }
    }

    private func destinationCard(label: String, systemImage: String, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Spacer()
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(QTheme.primaryInk)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(QTheme.primary)
                            .clipShape(Capsule())
                    }
                }
                Text(label)
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(.white)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: – Data

    private func load() async {
        loading = true
        async let inboxTask = InboxService.shared.listThreads(role: .org)
        async let jobsTask = OrgService.shared.listJobs()
        if let threads = try? await inboxTask {
            unreadInbox = threads.reduce(0) { $0 + $1.unreadCount }
        }
        if let jobs = try? await jobsTask {
            jobsCount = jobs.count
            newJobs = jobs.filter { $0.jobStatus == "new" }.count
        }
        loading = false
    }
}
