import SwiftUI
import ARKit

/// Post-upload success screen. Scope of work is now gathered inline with
/// room naming (see `RoomLabelView`) and mesh processing is shown as a
/// status chip in the 360 Room View, so this screen is intentionally
/// minimal — the scan is done, let the user move on.
struct ScanResultView: View {
    let viewModel: ScanViewModel
    let meshAnchors: [ARMeshAnchor]
    let onDone: () -> Void
    let onScanAnother: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if uploadFailed {
                failedView
            } else {
                successView
            }

            Spacer()

            footerActions
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
        }
        .padding()
        .background(QTheme.canvas.ignoresSafeArea())
        .dynamicTypeSize(.large ... .accessibility2)
    }

    private var uploadFailed: Bool {
        viewModel.uploadError != nil
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(QTheme.success)

            Text("Scan complete")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(QTheme.ink)

            Text(processingHint)
                .font(.callout)
                .foregroundStyle(QTheme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if let scanId = viewModel.lastScanId {
                Text(scanId.prefix(8) + "…")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(QTheme.inkDim)
            }
        }
    }

    private var failedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(QTheme.danger)

            Text("Upload failed")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(QTheme.ink)

            if let err = viewModel.uploadError {
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(QTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    private var processingHint: String {
        if viewModel.roomLabel.isEmpty {
            return "Your room is uploaded. The 3D model processes in the background — check the 360 Room View for status."
        } else {
            return "\(viewModel.roomLabel) is uploaded. The 3D model processes in the background — check the 360 Room View for status."
        }
    }

    private var footerActions: some View {
        VStack(spacing: 12) {
            Button(action: onDone) {
                Label("Done", systemImage: "house")
                    .primaryButtonStyle()
            }

            if let onScanAnother, !uploadFailed {
                Button(action: onScanAnother) {
                    Label("Scan Another Room", systemImage: "plus.viewfinder")
                }
                .largeCapsuleButton(role: .secondary)
            }
        }
    }
}

/// Wrap layout used by several scan-flow screens (RoomLabelView,
/// ProjectOverviewView). Kept at file scope here because it's the oldest
/// and most generic definition — other views have their own private
/// variants for chip layouts.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
