import SwiftUI

/// Combined room-naming + scope-of-work step. The scope was previously
/// gathered *after* upload on the results screen, which broke the
/// homeowner's flow because they'd already left the scan mentally. Now
/// it's captured inline before packaging so the scan lands on the server
/// already tagged with what work the customer wants done.
struct RoomLabelView: View {
    @Binding var roomLabel: String
    @Binding var roomScope: RoomScope?
    let onConfirm: () -> Void

    @State private var selectedScope: Set<String> = []
    @State private var notes: String = ""
    @FocusState private var nameFocused: Bool

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

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold)).tracking(0.5)
            .foregroundStyle(QTheme.inkMuted)
    }

    private func commit() {
        roomScope = RoomScope(items: Array(selectedScope), notes: notes)
    }
}
