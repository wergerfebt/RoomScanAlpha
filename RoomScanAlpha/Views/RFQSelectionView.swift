import SwiftUI

struct RFQSelectionView: View {
    @Binding var selectedRFQ: RFQ?
    @State private var rfqs: [RFQ] = []
    @State private var isLoading = true
    @State private var showNewRFQ = false
    @State private var newDescription = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading projects...")
                } else if rfqs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No projects yet")
                            .font(.headline)
                        Text("Create a project to start scanning")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List(rfqs) { rfq in
                        Button {
                            selectedRFQ = rfq
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rfq.description ?? "Untitled Project")
                                        .font(.headline)
                                    Text(rfq.status.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedRFQ?.id == rfq.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Select Project")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewRFQ = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Project", isPresented: $showNewRFQ) {
                TextField("Project description", text: $newDescription)
                Button("Create") { createRFQ() }
                Button("Cancel", role: .cancel) { newDescription = "" }
            }
            .task {
                await loadRFQs()
            }
        }
    }

    private func loadRFQs() async {
        isLoading = true
        do {
            _ = try await AuthManager.shared.signInAnonymously()
            rfqs = try await RFQService.shared.listRFQs()
        } catch {
            errorMessage = error.localizedDescription
            print("[RoomScanAlpha] Failed to load RFQs: \(error)")
        }
        isLoading = false
    }

    private func createRFQ() {
        let desc = newDescription
        newDescription = ""
        Task {
            do {
                let rfq = try await RFQService.shared.createRFQ(description: desc)
                rfqs.insert(rfq, at: 0)
                selectedRFQ = rfq
            } catch {
                errorMessage = error.localizedDescription
                print("[RoomScanAlpha] Failed to create RFQ: \(error)")
            }
        }
    }
}
