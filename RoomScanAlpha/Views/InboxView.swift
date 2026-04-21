import SwiftUI
import PhotosUI

/// Homeowner inbox — thread list + conversation view. Mirrors the mobile-web
/// `/inbox` pattern (2-page on narrow screens).
struct InboxView: View {
    let role: InboxService.Role
    let onClose: () -> Void

    init(role: InboxService.Role = .homeowner, onClose: @escaping () -> Void) {
        self.role = role
        self.onClose = onClose
    }

    @State private var threads: [InboxThread] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                Group {
                    if loading && threads.isEmpty {
                        ProgressView().tint(QTheme.primary)
                    } else if let error, threads.isEmpty {
                        errorState(error)
                    } else if threads.isEmpty {
                        emptyState
                    } else {
                        threadList
                    }
                }
            }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose)
                        .foregroundStyle(QTheme.ink)
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
        .tint(QTheme.primary)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(QTheme.inkDim)
            Text("No conversations yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(QTheme.ink)
            Text("Reach out to a contractor from their profile to start a message.")
                .font(.subheadline)
                .foregroundStyle(QTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text("Couldn't load inbox").font(.system(size: 17, weight: .semibold))
            Text(message).font(.subheadline).foregroundStyle(QTheme.inkMuted)
        }
        .padding(32)
    }

    private var threadList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(threads.enumerated()), id: \.element.id) { idx, thread in
                    if idx > 0 { Divider().background(QTheme.divider).padding(.leading, 78) }
                    NavigationLink {
                        ConversationView(thread: thread)
                    } label: {
                        threadRow(thread)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(QTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(QTheme.hairline, lineWidth: 0.5))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func threadRow(_ thread: InboxThread) -> some View {
        let cp = thread.counterpart
        return HStack(alignment: .top, spacing: 12) {
            avatar(cp)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(cp.name ?? "Unknown")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(QTheme.ink)
                        .lineLimit(1)
                    if thread.unreadCount > 0 {
                        Circle().fill(QTheme.primary).frame(width: 8, height: 8)
                    }
                    Spacer()
                    Text(relativeShort(thread.lastMessageAt ?? thread.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(QTheme.inkMuted)
                }
                Text(thread.rfqTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(QTheme.inkSoft)
                    .lineLimit(1)
                Text(thread.kindLabel)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.3)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(kindColor(thread.kind))
                    .background(kindColor(thread.kind).opacity(0.12))
                    .clipShape(Capsule())
                if let preview = thread.lastMessagePreview {
                    Text(previewText(thread, preview: preview))
                        .font(.system(size: 13))
                        .foregroundStyle(QTheme.inkMuted)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewText(_ thread: InboxThread, preview: String) -> String {
        if thread.lastMessageSide == "homeowner" { return "You: \(preview)" }
        return preview
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "won": return QTheme.primary
        case "bid": return QTheme.warning
        case "rfq": return QTheme.scanAccent
        default: return QTheme.inkMuted
        }
    }

    @ViewBuilder
    private func avatar(_ cp: InboxThread.Counterpart) -> some View {
        if let urlString = cp.iconURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initialsTile(cp.name)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            initialsTile(cp.name)
        }
    }

    private func initialsTile(_ name: String?) -> some View {
        let parts = (name ?? "?").split(separator: " ").prefix(2).compactMap { $0.first }
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(QTheme.primarySoft)
            .overlay(Text(String(parts)).font(.system(size: 14, weight: .bold)).foregroundStyle(QTheme.primary))
    }

    private func relativeShort(_ iso: String?) -> String {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        if diff < 7 * 86400 { return "\(Int(diff / 86400))d" }
        let df = DateFormatter(); df.dateFormat = "MMM d"
        return df.string(from: date)
    }

    private func load() async {
        loading = true
        do { threads = try await InboxService.shared.listThreads(role: role) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

// MARK: – Conversation view

struct ConversationView: View {
    let thread: InboxThread

    @State private var conversation: Conversation?
    @State private var input = ""
    @State private var sending = false
    @State private var error: String?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var pending: [PendingAttachment] = []
    @State private var uploading = false
    @FocusState private var composerFocused: Bool

    private struct PendingAttachment: Identifiable {
        let id = UUID()
        let previewData: Data
        let ref: InboxService.AttachmentRef
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = conversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(conversation.messages) { msg in
                                messageBubble(msg, role: conversation.callerSide)
                                    .id(msg.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                    }
                    .onAppear {
                        if let last = conversation.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: conversation.messages.count) { _, _ in
                        if let last = conversation.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            } else {
                ProgressView().tint(QTheme.primary).frame(maxWidth: .infinity).padding(.top, 80)
                Spacer()
            }

            composer
        }
        .background(QTheme.canvas.ignoresSafeArea())
        .navigationTitle(thread.counterpart.name ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: – Messages

    @ViewBuilder
    private func messageBubble(_ msg: Message, role: String) -> some View {
        if msg.kind == "event" {
            HStack(spacing: 6) {
                Circle().fill(QTheme.inkDim).frame(width: 5, height: 5)
                Text(eventText(msg))
                    .font(.system(size: 12))
                    .foregroundStyle(QTheme.inkMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } else if msg.kind == "bid" {
            let snap = msg.bidSnapshot
            let mine = msg.side == role
            HStack {
                if mine { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("BID SUBMITTED")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(QTheme.inkMuted)
                    if let cents = snap?.priceCents {
                        Text("$\(cents / 100)")
                            .font(.system(size: 22, weight: .bold))
                            .tracking(-0.5)
                            .foregroundStyle(QTheme.ink)
                    }
                    if let description = snap?.description, !description.isEmpty {
                        Text(description).font(.system(size: 13)).foregroundStyle(QTheme.inkSoft)
                    }
                }
                .padding(12)
                .background(QTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(QTheme.primarySoft, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                if !mine { Spacer(minLength: 40) }
            }
        } else {
            // Text message
            let mine = msg.side == role
            HStack {
                if mine { Spacer(minLength: 40) }
                VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                    if let body = msg.body, !body.isEmpty {
                        Text(body)
                            .font(.system(size: 15))
                            .foregroundStyle(mine ? QTheme.primaryInk : QTheme.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(mine ? QTheme.primary : QTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(mine ? .clear : QTheme.hairline, lineWidth: 0.5)
                            )
                    }
                    ForEach(msg.attachments) { att in
                        attachmentView(att, mine: mine)
                    }
                    if let when = relativeShort(msg.createdAt) {
                        Text(when).font(.system(size: 10)).foregroundStyle(QTheme.inkMuted)
                            .padding(.horizontal, 4)
                    }
                }
                if !mine { Spacer(minLength: 40) }
            }
        }
    }

    @ViewBuilder
    private func attachmentView(_ att: Message.Attachment, mine: Bool) -> some View {
        if let urlString = att.downloadURL, let url = URL(string: urlString) {
            let isImage = (att.contentType ?? "").hasPrefix("image/")
            if isImage {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(QTheme.surfaceMuted)
                    }
                }
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Link(destination: url) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill").foregroundStyle(QTheme.danger)
                        Text(att.name ?? "File")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(mine ? QTheme.primaryInk : QTheme.ink)
                            .lineLimit(1)
                    }
                    .padding(10)
                    .background(mine ? Color.white.opacity(0.18) : QTheme.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func eventText(_ msg: Message) -> String {
        if let body = msg.body, !body.isEmpty { return body }
        switch msg.eventType {
        case "bid_submitted": return "New bid submitted"
        case "bid_accepted": return "Bid accepted"
        case "bid_rejected": return "Another contractor was selected"
        case "rfq_updated": return "Project updated"
        default: return msg.eventType ?? "Update"
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !pending.isEmpty || uploading {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pending) { item in
                            ZStack(alignment: .topTrailing) {
                                if let image = UIImage(data: item.previewData) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button {
                                    pending.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 5, y: -5)
                                .buttonStyle(.plain)
                            }
                        }
                        if uploading {
                            ProgressView()
                                .frame(width: 64, height: 64)
                                .background(QTheme.surfaceMuted)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .tint(QTheme.primary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(QTheme.inkMuted)
                        .frame(width: 36, height: 36)
                }
                .onChange(of: pickerItems) { _, items in
                    Task { await ingestPhotos(items) }
                }

                TextField("Message…", text: $input, axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(QTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(QTheme.hairline, lineWidth: 0.5))

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(QTheme.primaryInk)
                        .frame(width: 40, height: 40)
                        .background(QTheme.primary)
                        .clipShape(Circle())
                        .opacity(sendDisabled ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(sendDisabled)
            }
        }
        .padding(12)
        .background(QTheme.canvas)
        .overlay(Rectangle().fill(QTheme.hairline).frame(height: 0.5), alignment: .top)
    }

    private var sendDisabled: Bool {
        let noText = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (noText && pending.isEmpty) || sending || uploading
    }

    private func relativeShort(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let df = DateFormatter(); df.dateFormat = "MMM d · h:mm a"
        return df.string(from: date)
    }

    private func load() async {
        do { conversation = try await InboxService.shared.getConversation(id: thread.id) }
        catch { self.error = error.localizedDescription }
    }

    /// Transfer chosen PhotosPicker items into uploaded attachments. Each
    /// item reserves a signed GCS URL and PUTs the image bytes. The slot
    /// becomes a PendingAttachment the composer previews.
    private func ingestPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        uploading = true
        defer {
            pickerItems = []
            uploading = false
        }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let contentType = item.supportedContentTypes
                    .first(where: { $0.preferredMIMEType != nil })?
                    .preferredMIMEType ?? "image/jpeg"
                let ext = contentType.split(separator: "/").last.map(String.init) ?? "jpg"
                let filename = "photo-\(Int(Date().timeIntervalSince1970)).\(ext)"
                let slot = try await InboxService.shared.attachmentUploadURL(
                    conversationId: thread.id,
                    contentType: contentType,
                    filename: filename
                )
                guard let url = URL(string: slot.uploadURL) else { continue }
                try await InboxService.shared.uploadAttachment(to: url, contentType: contentType, data: data)
                let ref = InboxService.AttachmentRef(
                    blobPath: slot.blobPath,
                    contentType: contentType,
                    name: filename,
                    sizeBytes: data.count
                )
                pending.append(PendingAttachment(previewData: data, ref: ref))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = pending.map(\.ref)
        guard !text.isEmpty || !refs.isEmpty else { return }
        sending = true
        do {
            try await InboxService.shared.sendMessage(
                conversationId: thread.id,
                body: text,
                attachments: refs
            )
            input = ""
            pending.removeAll()
            conversation = try await InboxService.shared.getConversation(id: thread.id)
        } catch {
            self.error = error.localizedDescription
        }
        sending = false
    }
}
