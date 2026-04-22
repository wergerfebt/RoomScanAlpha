// Reusable full-width button styling used across idle, scanning, and export screens.

import SwiftUI

extension View {
    /// Forest-gradient primary CTA. Used for the inline scope-step Continue,
    /// the Exporting / ScanResult Done buttons. Matches the gradient hero
    /// CTAs rendered via `largeCapsuleButton(role:.primary, gradient:)`.
    func primaryButtonStyle() -> some View {
        self
            .font(.title3)
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding()
            .background(QTheme.forestGradient)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    func disabledButtonStyle() -> some View {
        self
            .font(.title3)
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding()
            .background(QTheme.inkDim.opacity(0.3))
            .foregroundStyle(QTheme.inkMuted)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}
