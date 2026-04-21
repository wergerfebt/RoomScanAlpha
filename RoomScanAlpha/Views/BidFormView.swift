import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Contractor bid submit / update form. Mirrors the web ContractorBidForm:
/// big Total input, timeline + start date, note, PDF attachment, project
/// media. Submits via multipart POST /api/rfqs/{id}/bids.
struct BidFormView: View {
    let job: Job
    let onSaved: () -> Void
    let onClose: () -> Void

    @State private var total: String
    @State private var timeline: String
    @State private var startDate: String
    @State private var note: String
    @State private var imagePicker: [PhotosPickerItem] = []
    @State private var newImages: [PendingImage] = []
    @State private var pickedPDF: PendingPDF?
    @State private var showPDFPicker = false
    @State private var submitting = false
    @State private var error: String?

    private struct PendingImage: Identifiable {
        let id = UUID()
        let data: Data
        let contentType: String
        let filename: String
        let previewImage: UIImage?
    }

    private struct PendingPDF {
        let data: Data
        let filename: String
    }

    init(job: Job, onSaved: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.job = job
        self.onSaved = onSaved
        self.onClose = onClose

        let parsed = ParsedBidNote(from: job.bid?.description)
        let cents = job.bid?.priceCents ?? 0
        let dollars = Double(cents) / 100.0
        _total = State(initialValue: cents > 0 ? String(Int(dollars.rounded())) : "")
        _timeline = State(initialValue: parsed.timeline)
        _startDate = State(initialValue: parsed.start)
        _note = State(initialValue: parsed.note)
    }

    private var isUpdate: Bool { job.bid != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                QTheme.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        totalField
                        timelineFields
                        noteField
                        pdfCard
                        mediaCard
                        if let error, !error.isEmpty {
                            Text(error).font(.caption).foregroundStyle(QTheme.danger)
                        }
                        submitButton
                    }
                    .padding(20)
                }
            }
            .navigationTitle(isUpdate ? "Update bid" : "Submit bid")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onClose).foregroundStyle(QTheme.ink)
                }
            }
            .onChange(of: imagePicker) { _, items in
                if !items.isEmpty { Task { await ingestImages(items) } }
            }
            .fileImporter(
                isPresented: $showPDFPicker,
                allowedContentTypes: [UTType.pdf],
                allowsMultipleSelection: false
            ) { result in
                handlePDFPick(result)
            }
        }
        .tint(QTheme.primary)
    }

    // MARK: – Total

    private var totalField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Total")
            HStack(alignment: .center, spacing: 8) {
                Text("$")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(QTheme.inkMuted)
                TextField("12,500", text: $total)
                    .keyboardType(.numberPad)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(QTheme.ink)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(QTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(QTheme.hairline, lineWidth: 0.5))
        }
    }

    // MARK: – Timeline + start

    private var timelineFields: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Timeline")
                TextField("6 weeks", text: $timeline)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(QTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Start date")
                TextField("May 5", text: $startDate)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(QTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))
            }
        }
    }

    // MARK: – Note

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Note to customer")
            TextField("Anything else you want to tell the customer?", text: $note, axis: .vertical)
                .lineLimit(3...8)
                .font(.system(size: 15))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(QTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))
        }
    }

    // MARK: – PDF

    private var pdfCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Project breakdown PDF")
            Button {
                showPDFPicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(QTheme.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pdfLabel)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(QTheme.ink)
                            .lineLimit(1)
                        Text(pdfSubLabel)
                            .font(.caption)
                            .foregroundStyle(QTheme.inkMuted)
                    }
                    Spacer()
                    Image(systemName: "paperclip").foregroundStyle(QTheme.primary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            Text("Attach your full project breakdown so customers can compare your line items side-by-side with other bids.")
                .font(.caption).foregroundStyle(QTheme.inkMuted)
        }
    }

    private var pdfLabel: String {
        if let picked = pickedPDF { return picked.filename }
        if job.bid?.pdfURL != nil { return "Existing PDF attached" }
        return "Attach PDF"
    }

    private var pdfSubLabel: String {
        if pickedPDF != nil { return "Will replace existing PDF" }
        if job.bid?.pdfURL != nil { return "Tap to replace" }
        return "Tap to choose a file"
    }

    // MARK: – Media

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Project media")
            if newImages.isEmpty {
                PhotosPicker(selection: $imagePicker, maxSelectionCount: 10, matching: .images) {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 20))
                            .foregroundStyle(QTheme.primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add photos")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(QTheme.ink)
                            Text("Work samples, similar projects, before-and-afters")
                                .font(.caption)
                                .foregroundStyle(QTheme.inkMuted)
                        }
                        Spacer()
                        Image(systemName: "plus").foregroundStyle(QTheme.primary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(QTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(QTheme.hairline, lineWidth: 0.5))
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(newImages) { img in
                            ZStack(alignment: .topTrailing) {
                                if let ui = img.previewImage {
                                    Image(uiImage: ui)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 96, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                Button {
                                    newImages.removeAll { $0.id == img.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 5, y: -5)
                                .buttonStyle(.plain)
                            }
                        }
                        PhotosPicker(selection: $imagePicker, maxSelectionCount: 10, matching: .images) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(QTheme.hairline, lineWidth: 1)
                                .background(QTheme.surfaceMuted)
                                .frame(width: 96, height: 96)
                                .overlay(
                                    Image(systemName: "plus")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(QTheme.primary)
                                )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    // MARK: – Submit

    private var submitButton: some View {
        Button(action: submit) {
            HStack(spacing: 8) {
                if submitting { ProgressView().tint(.white) }
                Text(submitting ? "Submitting…" : (isUpdate ? "Update bid" : "Submit bid"))
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(QTheme.primaryInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(QTheme.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(canSubmit ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || submitting)
        .padding(.top, 8)
    }

    private var canSubmit: Bool {
        guard let amt = Double(total.replacingOccurrences(of: ",", with: "")), amt > 0 else { return false }
        if !isUpdate && pickedPDF == nil { return false }
        return true
    }

    // MARK: – Actions

    private func submit() {
        guard let amt = Double(total.replacingOccurrences(of: ",", with: "")), amt > 0 else { return }
        let cents = Int(amt * 100)

        var header: [String] = []
        let tl = timeline.trimmingCharacters(in: .whitespacesAndNewlines)
        let sd = startDate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tl.isEmpty { header.append("Timeline: \(tl)") }
        if !sd.isEmpty { header.append("Start: \(sd)") }
        let body = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let description: String
        if header.isEmpty { description = body }
        else { description = header.joined(separator: " · ") + "\n\n" + body }

        Task {
            submitting = true
            defer { submitting = false }
            do {
                try await RFQService.shared.submitBid(
                    rfqId: job.rfqId,
                    priceCents: cents,
                    description: description,
                    pdf: pickedPDF.map { ($0.data, "application/pdf", $0.filename) },
                    images: newImages.map { RFQService.BidImage(data: $0.data, contentType: $0.contentType, filename: $0.filename) }
                )
                onSaved()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func ingestImages(_ items: [PhotosPickerItem]) async {
        defer { imagePicker = [] }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ct = item.supportedContentTypes
                .first(where: { $0.preferredMIMEType != nil })?
                .preferredMIMEType ?? "image/jpeg"
            let ext = ct.split(separator: "/").last.map(String.init) ?? "jpg"
            let filename = "bid-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).\(ext)"
            newImages.append(PendingImage(
                data: data,
                contentType: ct,
                filename: filename,
                previewImage: UIImage(data: data)
            ))
        }
    }

    private func handlePDFPick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pickedPDF = PendingPDF(data: data, filename: url.lastPathComponent)
            } catch {
                self.error = error.localizedDescription
            }
        case .failure(let error):
            self.error = error.localizedDescription
        }
    }

    // MARK: – Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold)).tracking(0.5)
            .foregroundStyle(QTheme.inkMuted)
    }
}
