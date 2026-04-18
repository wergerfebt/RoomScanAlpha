import SwiftUI

// Banner shown below the HUD during scan to guide the user through the flow:
// stand still → walk slowly → keep moving → enough coverage. Driven entirely
// by `ScanViewModel.coachingState`.

struct ScanCoachOverlay: View {
    let state: ScanCoachingState

    var body: some View {
        HStack(spacing: 12) {
            icon
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .sensoryFeedback(.impact(weight: .light), trigger: state)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .getStarted:
            Image(systemName: "figure.stand")
        case .walkSlowly:
            Image(systemName: "figure.walk.motion")
                .symbolEffect(.pulse.wholeSymbol, options: .repeating)
        case .keepMoving:
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.pulse.wholeSymbol, options: .repeating)
        case .enoughCoverage:
            Image(systemName: "checkmark.circle.fill")
        }
    }

    private var color: Color {
        switch state {
        case .getStarted: return .blue
        case .walkSlowly: return .blue
        case .keepMoving: return .orange
        case .enoughCoverage: return .green
        }
    }

    private var message: String {
        switch state {
        case .getStarted:
            return "Stand near the center of the room, then tap Start Scan."
        case .walkSlowly:
            return "Walk slowly around the room. Point the camera at the walls, floor, and ceiling."
        case .keepMoving:
            return "Keep moving — try the corners you haven't covered yet."
        case .enoughCoverage:
            return "Great — you've covered enough. Tap Stop Scan any time."
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        ScanCoachOverlay(state: .getStarted)
        ScanCoachOverlay(state: .walkSlowly)
        ScanCoachOverlay(state: .keepMoving)
        ScanCoachOverlay(state: .enoughCoverage)
    }
    .padding()
    .background(Color.gray)
}
