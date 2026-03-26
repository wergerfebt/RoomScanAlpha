import SwiftUI

struct ScanningView: View {
    let sessionManager: ARSessionManager
    let viewModel: ScanViewModel
    let onStop: () -> Void

    var body: some View {
        ZStack {
            ARScanningView(sessionManager: sessionManager, viewModel: viewModel)
                .ignoresSafeArea()

            VStack {
                // Top HUD
                HStack(spacing: 12) {
                    statBadge(
                        icon: "triangle",
                        value: formatCount(viewModel.meshTriangleCount),
                        label: "triangles"
                    )
                    statBadge(
                        icon: "camera.fill",
                        value: "\(viewModel.keyframeCount)",
                        label: "frames"
                    )
                    statBadge(
                        icon: "cube.transparent",
                        value: "\(viewModel.meshAnchorCount)",
                        label: "anchors"
                    )
                }
                .padding(.top, 8)

                Spacer()

                // Stop button
                Button(action: onStop) {
                    Label("Stop Scan", systemImage: "stop.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
                .padding(.bottom, 32)
            }
        }
        .onAppear {
            sessionManager.onKeyframeCaptured = { count in
                DispatchQueue.main.async {
                    viewModel.updateKeyframeCount(count)
                }
            }
            sessionManager.startSession()
        }
        .onDisappear {
            sessionManager.pauseSession()
        }
    }

    private func statBadge(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}
