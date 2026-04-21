import SwiftUI
import FirebaseAuth

/// Minimal account screen — mirrors the essentials of the web /account page.
/// Shows the signed-in user's name + email. Expandable later with profile
/// editing, contractor-request, etc.
struct AccountView: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        profileCard
                        infoBlock
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Account")
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

    private var user: User? { Auth.auth().currentUser }

    private var initials: String {
        let name = user?.displayName ?? user?.email ?? "?"
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return String(parts).uppercased()
    }

    private var profileCard: some View {
        HStack(spacing: 16) {
            Group {
                if let photoURL = user?.photoURL {
                    AsyncImage(url: photoURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            initialsTile
                        }
                    }
                    .clipShape(Circle())
                } else {
                    initialsTile
                }
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(user?.displayName ?? user?.email ?? "Signed in")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(QTheme.ink)
                if let email = user?.email {
                    Text(email)
                        .font(.system(size: 13))
                        .foregroundStyle(QTheme.inkMuted)
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

    private var initialsTile: some View {
        Circle()
            .fill(QTheme.primarySoft)
            .overlay(Text(initials).font(.system(size: 22, weight: .bold)).foregroundStyle(QTheme.primary))
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PROFILE EDITING COMING SOON")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(QTheme.inkMuted)
            Text("To change your name, photo, or notification preferences, visit your account on the web at roomscanalpha.com.")
                .font(.system(size: 14))
                .foregroundStyle(QTheme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QTheme.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
