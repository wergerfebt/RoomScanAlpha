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
    /// Optional gradient fill for the hero scan-flow CTA. When set, replaces
    /// the solid `tint` background on `.primary` buttons so we can express the
    /// Quoterra forest gradient without losing the existing tint API for the
    /// rest of the app.
    var gradient: LinearGradient? = nil

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
            if let gradient { gradient } else { tint }
        case .secondary:
            if let gradient {
                gradient
            } else if hasExplicitTint {
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
            return (hasExplicitTint || gradient != nil) ? .white : .primary
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

    /// Forest-gradient hero variant for the most prominent scan-flow CTAs
    /// (Start Scan, Continue, Scan missing areas). Keeps the same shape and
    /// sizing as the solid-tint version.
    func largeCapsuleButton(
        role: ScanButtonRole = .primary,
        gradient: LinearGradient
    ) -> some View {
        self.buttonStyle(LargeCapsuleButtonStyle(role: role, gradient: gradient))
    }

    /// Conditional gradient: pass an optional gradient and a fallback tint.
    /// When `gradient` is nil the button paints with the solid tint instead.
    /// Useful for tier-aware buttons (e.g. Finish Room — gradient at 4+
    /// corners, muted solid otherwise) that need to switch fill style by
    /// state without duplicating the button declaration.
    func largeCapsuleButton(
        role: ScanButtonRole = .primary,
        tint: Color,
        gradient: LinearGradient?
    ) -> some View {
        self.buttonStyle(LargeCapsuleButtonStyle(role: role, tint: tint, gradient: gradient))
    }
}
