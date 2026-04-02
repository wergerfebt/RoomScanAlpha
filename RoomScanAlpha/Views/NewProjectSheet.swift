import SwiftUI

struct NewProjectSheet: View {
    let onCreate: (String, String, String) -> Void  // (title, description, address)

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var address = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Title
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Project Name")
                            .font(.headline)
                        TextField("e.g. Kitchen & Bath Remodel", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Address
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Property Address")
                            .font(.headline)
                        TextField("123 Main St, City, State", text: $address)
                            .textContentType(.fullStreetAddress)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Description
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description")
                            .font(.headline)
                        Text("Describe what you'd like done — the more detail, the better for accurate quotes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("What work do you need? Materials preferences? Timeline?", text: $description, axis: .vertical)
                            .lineLimit(4...10)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(24)
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(title, description, address)
                    }
                    .fontWeight(.semibold)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
