import SwiftUI
import FirebaseAuth

/// Home screen — replaces the generic "RoomScan Alpha" splash.
/// Greets the user, summarizes their project + bid state, offers a dark
/// "Scan a new room" capture CTA, and surfaces recent activity.
///
/// Matches the `QIosHome` wireframe. Recent activity is derived from the
/// `/api/rfqs` feed for now (new bids, processed scans) — full event-stream
/// integration can come later.
struct HomeView: View {
    /// Start a scan into the most-recently-touched project (or picker if none).
    let onStartScan: (RFQ?) -> Void
    /// Always opens the project picker.
    let onPickProject: () -> Void
    let onOpenProjects: () -> Void
    let onOpenAccount: () -> Void
    let onOpenSearch: () -> Void
    let onOpenInbox: () -> Void
    let onOpenHistory: () -> Void
    let onOpenWorkspace: () -> Void
    let onSignOut: () -> Void

    @State private var rfqs: [RFQ] = []
    @State private var account: Account?
    @State private var loading = true
    @State private var error: String?
    @State private var signOutConfirm = false

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hi"
        }
    }

    private var firstName: String {
        let name = Auth.auth().currentUser?.displayName ?? ""
        let parts = name.split(separator: " ")
        if let first = parts.first { return String(first) }
        if let email = Auth.auth().currentUser?.email {
            return email.split(separator: "@").first.map(String.init) ?? ""
        }
        return ""
    }

    private var initials: String {
        let name = Auth.auth().currentUser?.displayName ?? Auth.auth().currentUser?.email ?? "?"
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return String(parts).uppercased()
    }

    private var totalBids: Int {
        rfqs.reduce(0) { $0 + ($1.bidCount ?? 0) }
    }

    private var waitingBids: Int {
        // Bids that haven't been hired — for rfqs that aren't yet completed.
        rfqs.reduce(0) { acc, r in acc + (r.status == "completed" ? 0 : (r.bidCount ?? 0)) }
    }

    private var hasLiDAR: Bool { DeviceCapability.supportsLiDAR }

    /// The project the user worked on most recently. Used as the "current
    /// target" for the Start-scan CTA — mirrors how the iOS Photos app
    /// defaults the next photo to the active album.
    private var latestRFQ: RFQ? {
        rfqs
            .filter { $0.status != "completed" }
            .max { lhs, rhs in (lhs.createdAt ?? "") < (rhs.createdAt ?? "") }
    }

    private var captureTargetText: String {
        if let rfq = latestRFQ {
            return "to \(rfq.displayTitle)."
        } else {
            return "to a project."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                greetingBlock
                captureCard
                recentActivitySection
                Spacer(minLength: 24)
            }
            .padding(.bottom, 40)
        }
        .background(QTheme.canvas.ignoresSafeArea())
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Sign out?", isPresented: $signOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive, action: onSignOut)
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: – Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(QTheme.primary)
                    Text("Q")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(QTheme.primaryInk)
                }
                .frame(width: 34, height: 34)
                Text("Quoterra")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(QTheme.ink)
            }

            Spacer()

            iconButton(systemImage: "magnifyingglass", label: "Search", action: onOpenSearch)
            iconButton(systemImage: "envelope", label: "Inbox", action: onOpenInbox)

            Menu {
                if let org = account?.org {
                    Button {
                        onOpenWorkspace()
                    } label: {
                        Label {
                            Text("Workspace · \(org.name)")
                        } icon: {
                            Image(systemName: "briefcase")
                        }
                    }
                    Divider()
                }
                Button("My Projects", systemImage: "folder", action: onOpenProjects)
                Button("Account", systemImage: "person.circle", action: onOpenAccount)
                Button("Scan history", systemImage: "clock.arrow.circlepath", action: onOpenHistory)
                Divider()
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    signOutConfirm = true
                }
            } label: {
                Circle()
                    .fill(QTheme.primarySoft)
                    .overlay(Text(initials).font(.system(size: 13, weight: .bold)).foregroundStyle(QTheme.primary))
                    .frame(width: 34, height: 34)
                    .accessibilityLabel("Account")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func iconButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(QTheme.ink)
                .frame(width: 34, height: 34)
                .background(QTheme.surface)
                .overlay(Circle().strokeBorder(QTheme.hairline, lineWidth: 0.5))
                .clipShape(Circle())
                .accessibilityLabel(label)
        }
        .buttonStyle(.plain)
    }

    // MARK: – Greeting + stats

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingText)
                .font(.system(size: 15))
                .foregroundStyle(QTheme.inkMuted)
                .tracking(-0.2)
            if loading {
                // Skeleton while loading
                RoundedRectangle(cornerRadius: 6).fill(QTheme.surfaceMuted)
                    .frame(width: 220, height: 36).padding(.top, 2)
                RoundedRectangle(cornerRadius: 6).fill(QTheme.surfaceMuted)
                    .frame(width: 160, height: 28).padding(.top, 4)
            } else {
                Text(statsLineOne)
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(QTheme.ink)
                Text(statsLineTwo)
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(QTheme.inkMuted)
            }
        }
        .padding(.horizontal, 20)
    }

    private var greetingText: String {
        firstName.isEmpty ? greeting : "\(greeting), \(firstName)"
    }

    private var statsLineOne: String {
        let count = rfqs.count
        return "\(count) \(count == 1 ? "project" : "projects")"
    }

    private var statsLineTwo: String {
        if waitingBids == 0 { return "No bids yet" }
        return "\(waitingBids) \(waitingBids == 1 ? "bid" : "bids") waiting"
    }

    // MARK: – Scan CTA

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CAPTURE")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.7))
            (
                Text("Scan a new room\n").foregroundStyle(.white) +
                Text(captureTargetText).foregroundStyle(.white.opacity(0.65)).fontWeight(.medium)
            )
            .font(.system(size: 24, weight: .bold))
            .tracking(-0.4)
            .lineSpacing(2)
            .padding(.top, 10)

            HStack(spacing: 10) {
                Button {
                    onStartScan(latestRFQ)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Start scan").font(.system(size: 15, weight: .semibold))
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.white)
                    .foregroundStyle(QTheme.ink)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!hasLiDAR)
                .opacity(hasLiDAR ? 1 : 0.5)

                Button(action: onPickProject) {
                    Text(latestRFQ == nil ? "Pick project" : "Change project")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .overlay(
                            Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 20)

            if !hasLiDAR {
                Text("LiDAR scanner required")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 12)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Single background containing both the ink fill and a top-right
        // forest glow. Using a layered gradient instead of an offset circle
        // avoids the clipped-box artifact at the card edge.
        .background(
            ZStack {
                QTheme.ink
                RadialGradient(
                    colors: [QTheme.primary.opacity(0.55), .clear],
                    center: UnitPoint(x: 0.95, y: 0.0),
                    startRadius: 0,
                    endRadius: 260
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 20)
    }

    // MARK: – Recent activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                Text("RECENT ACTIVITY")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(QTheme.inkMuted)
                Spacer()
                Button(action: onPickProject) {
                    Text("See all")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(QTheme.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

            let entries = activityEntries
            if entries.isEmpty {
                Text(loading ? "Loading…" : "No activity yet — create a project to get started.")
                    .font(.subheadline)
                    .foregroundStyle(QTheme.inkMuted)
                    .padding(.horizontal, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        if idx > 0 { Divider().background(QTheme.divider).padding(.leading, 54) }
                        activityRow(entry)
                    }
                }
                .background(QTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(QTheme.hairline, lineWidth: 0.5)
                )
                .padding(.horizontal, 20)
            }
        }
    }

    private func activityRow(_ entry: ActivityEntry) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(entry.color)
                .frame(width: 10, height: 10)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(QTheme.ink)
                    .lineLimit(1)
                Text(entry.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(QTheme.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(entry.time)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(QTheme.inkMuted)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
    }

    // MARK: – Derived activity entries

    private struct ActivityEntry: Identifiable {
        let id: String
        let color: Color
        let title: String
        let detail: String
        let time: String
    }

    private var activityEntries: [ActivityEntry] {
        // Derive from recent RFQs. Later: pull from inbox events / conversations.
        let sorted = rfqs.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        return sorted.prefix(5).map { rfq in
            let nBids = rfq.bidCount ?? 0
            let hired = rfq.status == "completed"
            let color: Color = hired ? QTheme.primary : (nBids > 0 ? QTheme.success : QTheme.warning)
            let title: String
            let detail: String
            if hired {
                title = "Hired on \(rfq.displayTitle)"
                detail = rfq.address ?? "Ready to start"
            } else if nBids > 0 {
                title = "\(nBids) \(nBids == 1 ? "bid" : "bids") in — \(rfq.displayTitle)"
                detail = rfq.address ?? "Compare and hire"
            } else {
                title = "Waiting on bids — \(rfq.displayTitle)"
                detail = rfq.address ?? "Share with contractors"
            }
            return ActivityEntry(
                id: rfq.id,
                color: color,
                title: title,
                detail: detail,
                time: relativeShort(rfq.createdAt)
            )
        }
    }

    private func relativeShort(_ iso: String?) -> String {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        if diff < 7 * 86400 { return "\(Int(diff / 86400))d" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: date)
    }

    // MARK: – Data

    private func load() async {
        loading = true
        // Run in parallel — neither depends on the other, and the account
        // query is cheap (short-circuits on 401 if sign-in expired).
        async let rfqsTask = RFQService.shared.listRFQs()
        async let accountTask = AccountService.shared.getAccount()
        do {
            rfqs = try await rfqsTask
        } catch {
            self.error = error.localizedDescription
        }
        if let fetched = try? await accountTask {
            account = fetched
        }
        loading = false
    }
}
