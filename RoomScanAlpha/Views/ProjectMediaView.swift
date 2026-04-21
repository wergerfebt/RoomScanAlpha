import SwiftUI
import PhotosUI

/// Project media strip — photos the homeowner attaches to their RFQ
/// (current inspiration, existing conditions, etc.). Both homeowner
/// (project detail) and contractors with a bid/conversation can read;
/// only the owner can add/remove.
struct ProjectMediaView: View {
    let rfqId: String
    let canEdit: Bool

    @State private var attachments: [RFQService.RFQAttachment] = []
    @State private var loading = true
    @State private var picker: [PhotosPickerItem] = []
    @State private var uploadingCount = 0
    @State private var lightboxStart: Int?
    @State private var deleteTarget: RFQService.RFQAttachment?
    @State private var error: String?

    private struct StartIndex: Identifiable { let value: Int; var id: Int { value } }

    private var lightboxPhotos: [LightboxPhoto] {
        attachments.compactMap { att in
            guard let urlString = att.downloadURL, let url = URL(string: urlString) else { return nil }
            return LightboxPhoto(id: att.id, after: url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PROJECT MEDIA")
                    .font(.system(size: 12, weight: .bold)).tracking(0.5)
                    .foregroundStyle(QTheme.inkMuted)
                Spacer()
                if canEdit {
                    PhotosPicker(selection: $picker, maxSelectionCount: 6, matching: .images) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                            Text("Add").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(QTheme.primary)
                    }
                }
            }

            if loading && attachments.isEmpty && uploadingCount == 0 {
                ProgressView().tint(QTheme.primary).frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if attachments.isEmpty && uploadingCount == 0 {
                Text(canEdit
                     ? "Add photos of current conditions or inspiration to help contractors quote accurately."
                     : "The homeowner hasn't attached any reference photos yet.")
                    .font(.callout)
                    .foregroundStyle(QTheme.inkMuted)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(QTheme.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if uploadingCount > 0 {
                            ForEach(0..<uploadingCount, id: \.self) { _ in
                                uploadingTile
                            }
                        }
                        ForEach(Array(attachments.enumerated()), id: \.element.id) { idx, att in
                            tile(att, index: idx)
                        }
                    }
                }
            }

            if let error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(QTheme.danger)
            }
        }
        .task { await load() }
        .onChange(of: picker) { _, items in
            if !items.isEmpty { Task { await ingest(items) } }
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
        ) { att in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await delete(att) }
            }
        } message: { _ in
            Text("Contractors who have already bid will no longer see this photo.")
        }
    }

    private var uploadingTile: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(QTheme.surfaceMuted)
            .frame(width: 140, height: 140)
            .overlay(ProgressView().tint(QTheme.primary))
    }

    @ViewBuilder
    private func tile(_ att: RFQService.RFQAttachment, index: Int) -> some View {
        if let urlString = att.downloadURL, let url = URL(string: urlString) {
            ZStack(alignment: .topTrailing) {
                Button { lightboxStart = index } label: {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Rectangle().fill(QTheme.surfaceMuted)
                        }
                    }
                    .frame(width: 140, height: 140)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                if canEdit {
                    Button { deleteTarget = att } label: {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
        }
    }

    // MARK: – Data

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            attachments = try await RFQService.shared.listProjectAttachments(rfqId: rfqId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func ingest(_ items: [PhotosPickerItem]) async {
        defer { picker = [] }
        var toRegister: [(blobPath: String, contentType: String, name: String?, sizeBytes: Int?)] = []
        for item in items {
            uploadingCount += 1
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    uploadingCount -= 1
                    continue
                }
                let contentType = item.supportedContentTypes
                    .first(where: { $0.preferredMIMEType != nil })?
                    .preferredMIMEType ?? "image/jpeg"
                let ext = contentType.split(separator: "/").last.map(String.init) ?? "jpg"
                let filename = "photo-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).\(ext)"
                let slot = try await RFQService.shared.attachmentUploadURL(rfqId: rfqId, contentType: contentType, filename: filename)
                guard let url = URL(string: slot.uploadURL) else { uploadingCount -= 1; continue }
                try await RFQService.shared.uploadAttachmentBytes(to: url, contentType: contentType, data: data)
                toRegister.append((slot.blobPath, contentType, filename, data.count))
            } catch {
                self.error = error.localizedDescription
            }
            uploadingCount -= 1
        }
        if !toRegister.isEmpty {
            do {
                try await RFQService.shared.registerProjectAttachments(rfqId: rfqId, items: toRegister)
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func delete(_ att: RFQService.RFQAttachment) async {
        do {
            try await RFQService.shared.deleteProjectAttachment(rfqId: rfqId, attachmentId: att.attachmentId)
            attachments.removeAll { $0.id == att.id }
            deleteTarget = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
