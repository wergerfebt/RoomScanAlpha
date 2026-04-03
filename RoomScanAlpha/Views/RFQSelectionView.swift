import SwiftUI

struct RFQSelectionView: View {
    @Binding var selectedRFQ: RFQ?
    @State private var rfqs: [RFQ] = []
    @State private var isLoading = true
    @State private var showNewProject = false
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
                                    Text(rfq.title)
                                        .font(.headline)
                                    if let address = rfq.address, !address.isEmpty {
                                        Text(address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
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
                        showNewProject = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewProject) {
                NewProjectSheet { title, description, address in
                    showNewProject = false
                    createRFQ(title: title, description: description, address: address)
                }
            }
            .task {
                await loadRFQs()
            }
        }
    }

    private func loadRFQs() async {
        isLoading = true
        do {
            rfqs = try await RFQService.shared.listRFQs()
        } catch {
            errorMessage = error.localizedDescription
            print("[RoomScanAlpha] Failed to load RFQs: \(error)")
        }
        isLoading = false
    }

    private func createRFQ(title: String, description: String, address: String) {
        // Use title as the description if no separate description provided,
        // since the API stores description as the primary project text
        let desc = description.isEmpty ? title : "\(title) — \(description)"
        Task {
            do {
                let rfq = try await RFQService.shared.createRFQ(
                    description: desc,
                    address: address.isEmpty ? nil : address
                )
                rfqs.insert(rfq, at: 0)
                selectedRFQ = rfq
            } catch {
                errorMessage = error.localizedDescription
                print("[RoomScanAlpha] Failed to create RFQ: \(error)")
            }
        }
    }
}
