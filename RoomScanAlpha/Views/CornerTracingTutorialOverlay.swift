import SwiftUI

// One-time walkthrough shown before the first corner annotation. Three pages,
// dismissible, re-triggerable from the `i` icon on the prompt banner.

struct CornerTracingTutorialOverlay: View {
    let onDismiss: () -> Void

    @State private var page: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                tracePage.tag(0)
                aimPage.tag(1)
                finishPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 2 {
                    withAnimation { page += 1 }
                } else {
                    onDismiss()
                }
            } label: {
                Text(page == 2 ? "Got it" : "Next")
            }
            .largeCapsuleButton(role: .primary, gradient: QTheme.forestGradient)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .dynamicTypeSize(.large ... .accessibility2)
    }

    // MARK: - Pages

    private var tracePage: some View {
        pageScaffold(
            title: "Trace your room",
            body: "Tap each corner where two walls meet the ceiling. You'll connect them to form the shape of your room.",
            illustration: { FloorPlanIllustration(closed: false) }
        )
    }

    private var aimPage: some View {
        pageScaffold(
            title: "Aim at each ceiling corner",
            body: "Point the crosshair at a ceiling corner, then tap Add Corner. A yellow marker drops in.",
            illustration: { CrosshairIllustration() }
        )
    }

    private var finishPage: some View {
        pageScaffold(
            title: "Tap Finish Room when done",
            body: "Once you've placed every corner, tap Finish Room. The shape closes and turns green.",
            illustration: { FloorPlanIllustration(closed: true) }
        )
    }

    private func pageScaffold<Illustration: View>(
        title: String,
        body: String,
        @ViewBuilder illustration: () -> Illustration
    ) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 16)
            illustration()
                .frame(height: 220)
                .padding(.horizontal, 40)
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            Text(body)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer(minLength: 24)
        }
    }
}

// MARK: - Illustrations

private struct FloorPlanIllustration: View {
    let closed: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let inset: CGFloat = 20
            let rect = CGRect(
                x: inset,
                y: inset,
                width: size.width - inset * 2,
                height: size.height - inset * 2
            )
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY)
            ]

            ZStack {
                // Polygon edges
                Path { path in
                    path.addLines(corners)
                    if closed { path.closeSubpath() }
                }
                .stroke(
                    closed ? Color.green : Color.blue,
                    style: StrokeStyle(
                        lineWidth: 3,
                        dash: closed ? [] : [6, 6]
                    )
                )

                if closed {
                    Path { path in
                        path.addLines(corners)
                        path.closeSubpath()
                    }
                    .fill(Color.green.opacity(0.2))
                }

                // Numbered corner markers
                ForEach(0..<corners.count, id: \.self) { i in
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Text("\(i + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.black)
                        )
                        .position(corners[i])
                }
            }
        }
    }
}

private struct CrosshairIllustration: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let corner = CGPoint(x: size.width * 0.78, y: size.height * 0.22)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.15))

                // Ceiling corner marker (yellow sphere)
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Text("1")
                            .font(.caption.bold())
                            .foregroundStyle(.black)
                    )
                    .position(corner)

                // Aim arrow from crosshair to corner
                Path { path in
                    path.move(to: center)
                    path.addLine(to: corner)
                }
                .stroke(Color.blue.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))

                // Crosshair at screen center
                ZStack {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 28, height: 2)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: 28)
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                }
                .position(center)
            }
        }
    }
}

#Preview {
    CornerTracingTutorialOverlay(onDismiss: {})
}
