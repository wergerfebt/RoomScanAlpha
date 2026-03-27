// Displays export progress, completion status, and scan statistics after a scan is packaged.

import SwiftUI

struct ExportingView: View {
    let viewModel: ScanViewModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if viewModel.lastExportURL != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
            } else if viewModel.exportError != nil {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)
            } else {
                ProgressView()
                    .scaleEffect(2)
            }

            Text(viewModel.exportProgress)
                .font(.headline)
                .multilineTextAlignment(.center)

            if let error = viewModel.exportError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            if viewModel.lastExportURL != nil {
                VStack(spacing: 8) {
                    Text("\(viewModel.keyframeCount) keyframes")
                    Text("\(viewModel.meshTriangleCount) triangles")
                    Text("\(viewModel.meshAnchorCount) mesh anchors")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if viewModel.lastExportURL != nil || viewModel.exportError != nil {
                Button(action: onDone) {
                    Label("Done", systemImage: "house")
                        .primaryButtonStyle()
                }
                .padding(.horizontal, 40)
            }

            Spacer()
        }
        .padding()
    }
}
