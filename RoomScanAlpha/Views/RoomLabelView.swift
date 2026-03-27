import SwiftUI

struct RoomLabelView: View {
    @Binding var roomLabel: String
    let onConfirm: () -> Void

    private let suggestions = ["Kitchen", "Living Room", "Bedroom", "Bathroom", "Dining Room", "Office", "Hallway", "Garage", "Basement", "Laundry Room"]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "tag")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Name This Room")
                .font(.title2)
                .fontWeight(.bold)

            TextField("Room name", text: $roomLabel)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .padding(.horizontal, 40)

            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { label in
                    Button {
                        roomLabel = label
                    } label: {
                        Text(label)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(roomLabel == label ? .blue : .blue.opacity(0.1))
                            .foregroundStyle(roomLabel == label ? .white : .blue)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 24)

            Button(action: onConfirm) {
                Label("Continue", systemImage: "arrow.right")
                    .primaryButtonStyle()
            }
            .disabled(roomLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
    }
}
