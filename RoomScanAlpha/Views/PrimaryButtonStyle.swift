// Reusable full-width button styling used across idle, scanning, and export screens.

import SwiftUI

extension View {
    func primaryButtonStyle(color: Color = .blue) -> some View {
        self
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(color)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    func disabledButtonStyle() -> some View {
        self
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.gray.opacity(0.3))
            .foregroundStyle(.gray)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
