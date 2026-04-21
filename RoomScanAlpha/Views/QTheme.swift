import SwiftUI

/// Quoterra design tokens, mirroring `cloud/frontend/src/styles/tokens.css`.
/// The forest palette is the marketplace accent; the scan accent stays
/// indigo across every palette to keep scan/floor-plan visuals consistent.
enum QTheme {
    // Marketplace palette — forest
    static let primary       = Color(hex: 0x2F6A4B)
    static let primarySoft   = Color(hex: 0xE4EFE7)
    static let primaryInk    = Color.white

    // Surfaces
    static let canvas        = Color(hex: 0xF3F1EB) // warm off-white page bg
    static let surface       = Color.white
    static let surfaceMuted  = Color(hex: 0xF9F7F1)

    // Ink
    static let ink           = Color(hex: 0x141A16)
    static let inkSoft       = Color(hex: 0x33403A)
    static let inkMuted      = Color(hex: 0x66726B)
    static let inkDim        = Color(hex: 0x9AA39D)

    // Semantic
    static let success       = Color(hex: 0x2F6A4B)
    static let warning       = Color(hex: 0xB87414)
    static let danger        = Color(hex: 0xB03A2E)

    // Scan / floor plans — always indigo
    static let scanAccent     = Color(hex: 0x2B4FE0)
    static let scanAccentSoft = Color(hex: 0xE8EDFF)

    // Hairlines / dividers
    static let hairline      = Color(hex: 0x141A16).opacity(0.09)
    static let divider       = Color(hex: 0x141A16).opacity(0.06)

    // Radii
    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 16
    static let radiusXLarge: CGFloat = 20
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
