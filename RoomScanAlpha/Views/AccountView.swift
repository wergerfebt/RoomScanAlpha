import SwiftUI
import FirebaseAuth
import PhotosUI

/// Account profile editor — name, phone, address, and avatar. Mirrors
/// the web /account page. Email is read-only (Firebase-controlled).
struct AccountView: View {
    let onClose: () -> Void

    @State private var account: Account?
    @State private var name: String = ""
    @State private var phone: String = ""
    @State private var address: String = ""
    @State private var saving = false
    @State private var loading = true
    @State private var error: String?
    @State private var iconPicker: PhotosPickerItem?
    @State private var uploadingIcon = false

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        profileCard
                        profileForm
                        if let error, !error.isEmpty {
                            Text(error).font(.caption).foregroundStyle(QTheme.danger)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose).foregroundStyle(QTheme.ink)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: save) {
                        if saving { ProgressView().tint(QTheme.primary) }
                        else {
                            Text("Save").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(QTheme.primary)
                        }
                    }
                    .disabled(saving || !hasChanges)
                }
            }
            .task { await load() }
            .onChange(of: iconPicker) { _, item in
                if let item { Task { await uploadIcon(item) } }
            }
        }
        .tint(QTheme.primary)
    }

    private var user: User? { Auth.auth().currentUser }

    private var hasChanges: Bool {
        (account?.name ?? "") != name
    }

    private var initials: String {
        let source = account?.name ?? user?.displayName ?? user?.email ?? "?"
        let parts = source.split(separator: " ").prefix(2).compactMap { $0.first }
        return String(parts).uppercased()
    }

    private var profileCard: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                avatar
                    .frame(width: 72, height: 72)

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

            VStack(alignment: .leading, spacing: 4) {
                Text(account?.name ?? user?.displayName ?? "—")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(QTheme.ink)
                if let email = account?.email ?? user?.email {
                    Text(email).font(.system(size: 13)).foregroundStyle(QTheme.inkMuted)
                }
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

    @ViewBuilder
    private var avatar: some View {
        let accountIcon = account?.iconURL.flatMap { URL(string: $0) }
        let firebaseIcon = user?.photoURL
        if let url = accountIcon ?? firebaseIcon {
            AsyncImage(url: url) { phase in
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

    private var initialsTile: some View {
        Circle()
            .fill(QTheme.primarySoft)
            .overlay(Text(initials).font(.system(size: 24, weight: .bold)).foregroundStyle(QTheme.primary))
    }

    private var profileForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Profile")
            field(label: "Name") {
                TextField("Your name", text: $name)
                    .textContentType(.name)
            }
            field(label: "Phone") {
                TextField("Optional", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
            }
            field(label: "Address") {
                TextField("Street, City, State", text: $address, axis: .vertical)
                    .lineLimit(1...3)
                    .textContentType(.fullStreetAddress)
            }
        }
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(QTheme.inkSoft)
            content()
                .font(.system(size: 16))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(QTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold)).tracking(0.5)
            .foregroundStyle(QTheme.inkMuted)
    }

    // MARK: – Data

    private func load() async {
        loading = true
        do {
            let a = try await AccountService.shared.getAccount()
            account = a
            name = a.name ?? ""
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func save() {
        Task {
            saving = true
            defer { saving = false }
            var fields: [String: Any] = [:]
            fields["name"] = name
            if !phone.isEmpty { fields["phone"] = phone }
            if !address.isEmpty { fields["address"] = address }
            do {
                try await AccountService.shared.updateAccount(fields: fields)
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func uploadIcon(_ item: PhotosPickerItem) async {
        uploadingIcon = true
        defer {
            uploadingIcon = false
            iconPicker = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let contentType = item.supportedContentTypes
                .first(where: { $0.preferredMIMEType != nil })?
                .preferredMIMEType ?? "image/jpeg"
            let slot = try await AccountService.shared.iconUploadURL(contentType: contentType)
            guard let url = URL(string: slot.uploadURL) else { return }
            try await AccountService.shared.uploadIcon(to: url, contentType: contentType, data: data)
            try await AccountService.shared.updateAccount(fields: ["icon_url": slot.blobPath])
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
