import SwiftUI
import PhotosUI

/// Combined room-naming + scope-of-work step. The scope was previously
/// gathered *after* upload on the results screen, which broke the
/// homeowner's flow because they'd already left the scan mentally. Now
/// it's captured inline before packaging so the scan lands on the server
/// already tagged with what work the customer wants done.
struct RoomLabelView: View {
    @Binding var roomLabel: String
    @Binding var roomScope: RoomScope?
    /// RFQ to attach reference photos to. May be nil if the scan isn't bound
    /// to an RFQ yet — in that case the reference-photos section is hidden.
    var rfqId: String? = nil
    let onConfirm: () -> Void

    @State private var selectedScope: Set<String> = []
    @State private var notes: String = ""
    @FocusState private var nameFocused: Bool
    @State private var photoPicks: [PhotosPickerItem] = []
    @State private var uploadedPhotos: [RFQService.RFQAttachment] = []
    @State private var uploadingPhotoCount = 0
    @State private var photoError: String?

    private let suggestions = [
        "Kitchen", "Living Room", "Bedroom", "Bathroom",
        "Dining Room", "Office", "Hallway", "Garage",
        "Basement", "Laundry Room",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Spacer().frame(height: 8)

                header
                nameSection
                scopeSection
                if rfqId != nil { referencePhotosSection }

                Button {
                    commit()
                    onConfirm()
                } label: {
                    Label("Continue", systemImage: "arrow.right")
                        .primaryButtonStyle()
                }
                .disabled(roomLabel.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer(minLength: 28)
            }
            .padding(20)
        }
        .background(QTheme.canvas.ignoresSafeArea())
        .onAppear {
            if let existing = roomScope {
                selectedScope = Set(existing.items)
                notes = existing.notes
            }
        }
        .onChange(of: photoPicks) { _, items in
            if !items.isEmpty { Task { await ingestPhotos(items) } }
        }
        .dynamicTypeSize(.large ... .accessibility2)
    }

    // MARK: – Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "tag")
                .font(.system(size: 36))
                .foregroundStyle(QTheme.scanAccent)
            Text("Room details")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(QTheme.ink)
            Text("Name the room and pick the work you want done. Contractors bid against this list.")
                .font(.callout)
                .foregroundStyle(QTheme.inkMuted)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Name")

            TextField("Room name", text: $roomLabel)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { nameFocused = false }
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.system(size: 17))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(QTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { nameFocused = true }

            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { label in
                    Button {
                        roomLabel = label
                    } label: {
                        Text(label)
                            .font(.subheadline)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(roomLabel == label ? QTheme.primary : QTheme.primarySoft)
                            .foregroundStyle(roomLabel == label ? QTheme.primaryInk : QTheme.primary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Scope of work")
            Text("What work do you want a contractor to do in this room?")
                .font(.caption)
                .foregroundStyle(QTheme.inkMuted)

            let items = ScopeItemCatalog.items(for: roomLabel)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 { Divider().background(QTheme.divider) }
                    Button {
                        if selectedScope.contains(item.id) { selectedScope.remove(item.id) }
                        else { selectedScope.insert(item.id) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedScope.contains(item.id) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 18))
                                .foregroundStyle(selectedScope.contains(item.id) ? QTheme.primary : QTheme.inkDim)
                            Text(item.label)
                                .font(.system(size: 15))
                                .foregroundStyle(QTheme.ink)
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(QTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(QTheme.hairline, lineWidth: 0.5))

            TextField("Anything specific the contractor should know? (optional)", text: $notes, axis: .vertical)
                .lineLimit(2...5)
                .font(.system(size: 15))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(QTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))
        }
    }

    private var referencePhotosSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Reference photos")
                Spacer()
                PhotosPicker(selection: $photoPicks, maxSelectionCount: 6, matching: .images) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        Text("Add").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(QTheme.primary)
                }
            }

            Text("Optional. Add inspiration shots, existing conditions, or product picks — contractors see these alongside the scan.")
                .font(.caption)
                .foregroundStyle(QTheme.inkMuted)

            if uploadedPhotos.isEmpty && uploadingPhotoCount == 0 {
                Text("No photos yet")
                    .font(.callout)
                    .foregroundStyle(QTheme.inkMuted)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(QTheme.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<uploadingPhotoCount, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(QTheme.surfaceMuted)
                                .frame(width: 96, height: 96)
                                .overlay(ProgressView().tint(QTheme.primary))
                        }
                        ForEach(uploadedPhotos) { att in
                            photoTile(att)
                        }
                    }
                }
            }

            if let photoError, !photoError.isEmpty {
                Text(photoError).font(.caption).foregroundStyle(QTheme.danger)
            }
        }
    }

    @ViewBuilder
    private func photoTile(_ att: RFQService.RFQAttachment) -> some View {
        if let urlString = att.downloadURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(QTheme.surfaceMuted)
                }
            }
            .frame(width: 96, height: 96)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold)).tracking(0.5)
            .foregroundStyle(QTheme.inkMuted)
    }

    private func commit() {
        roomScope = RoomScope(items: Array(selectedScope), notes: notes)
    }

    private func ingestPhotos(_ items: [PhotosPickerItem]) async {
        defer { photoPicks = [] }
        guard let rfqId else { return }
        var toRegister: [(blobPath: String, contentType: String, name: String?, sizeBytes: Int?)] = []
        for item in items {
            uploadingPhotoCount += 1
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    uploadingPhotoCount -= 1
                    continue
                }
                let contentType = item.supportedContentTypes
                    .first(where: { $0.preferredMIMEType != nil })?
                    .preferredMIMEType ?? "image/jpeg"
                let ext = contentType.split(separator: "/").last.map(String.init) ?? "jpg"
                let filename = "ref-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).\(ext)"
                let slot = try await RFQService.shared.attachmentUploadURL(rfqId: rfqId, contentType: contentType, filename: filename)
                guard let url = URL(string: slot.uploadURL) else { uploadingPhotoCount -= 1; continue }
                try await RFQService.shared.uploadAttachmentBytes(to: url, contentType: contentType, data: data)
                toRegister.append((slot.blobPath, contentType, filename, data.count))
            } catch {
                photoError = error.localizedDescription
            }
            uploadingPhotoCount -= 1
        }
        if !toRegister.isEmpty {
            do {
                try await RFQService.shared.registerProjectAttachments(rfqId: rfqId, items: toRegister)
                uploadedPhotos = try await RFQService.shared.listProjectAttachments(rfqId: rfqId)
            } catch {
                photoError = error.localizedDescription
            }
        }
    }
}
