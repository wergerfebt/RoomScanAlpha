import SwiftUI

// Shared button styling for scan-flow actions. Sized for older users and
// accessibility: minimum 56pt hit target, Dynamic Type clamped to
// accessibility2 so labels don't blow past the viewport.

enum ScanButtonRole {
    case primary
    case secondary
    case tertiary
}

struct LargeCapsuleButtonStyle: ButtonStyle {
    var role: ScanButtonRole = .primary
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .fontWeight(.semibold)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: 56)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
            .overlay(borderOverlay)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityAddTraits(.isButton)
    }

    private var font: Font {
        switch role {
        case .primary: return .title3
        case .secondary: return .headline
        case .tertiary: return .subheadline
        }
    }

    private var horizontalPadding: CGFloat {
        switch role {
        case .primary: return 32
        case .secondary: return 24
        case .tertiary: return 20
        }
    }

    private var verticalPadding: CGFloat {
        switch role {
        case .primary: return 18
        case .secondary: return 14
        case .tertiary: return 12
        }
    }

    /// Whether the caller supplied an explicit tint (vs. accepting the default
    /// `.accentColor`). Used to decide whether the secondary role should fill
    /// itself with the tint color or fall back to a neutral material.
    private var hasExplicitTint: Bool {
        tint != .accentColor
    }

    @ViewBuilder
    private var background: some View {
        switch role {
        case .primary:
            tint
        case .secondary:
            if hasExplicitTint {
                tint
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        case .tertiary:
            Color.clear
        }
    }

    private var foreground: Color {
        switch role {
        case .primary:
            return .white
        case .secondary:
            return hasExplicitTint ? .white : .primary
        case .tertiary:
            return .primary
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if role == .tertiary {
            Capsule().stroke(.secondary.opacity(0.4), lineWidth: 1)
        }
    }
}

extension View {
    func largeCapsuleButton(
        role: ScanButtonRole = .primary,
        tint: Color = .accentColor
    ) -> some View {
        self.buttonStyle(LargeCapsuleButtonStyle(role: role, tint: tint))
    }
}
