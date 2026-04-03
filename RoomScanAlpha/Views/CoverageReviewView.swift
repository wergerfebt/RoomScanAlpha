// Shows mesh coverage analysis results after scanning.
// User can continue scanning to fill gaps or proceed to annotation.

import SwiftUI

struct CoverageReviewView: View {
    let sessionManager: ARSessionManager
    let viewModel: ScanViewModel
    let onContinueScanning: () -> Void
    let onLooksGood: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            coverageIcon

            Text("Scan Coverage")
                .font(.title2)
                .fontWeight(.bold)

            if viewModel.isAnalyzingCoverage {
                ProgressView("Analyzing mesh coverage...")
                    .padding()
            } else {
                coverageSummary
            }

            Spacer()

            controlButtons
                .padding(.bottom, 40)
        }
        .padding()
    }

    private var coverageIcon: some View {
        let pct = Int(viewModel.coverageRatio * 100)
        let color: Color = pct >= 95 ? .green : pct >= 80 ? .yellow : .red
        let icon = pct >= 95 ? "checkmark.circle.fill" : pct >= 80 ? "exclamationmark.circle.fill" : "xmark.circle.fill"

        return Image(systemName: icon)
            .font(.system(size: 64))
            .foregroundStyle(color)
    }

    private var coverageSummary: some View {
        let pct = Int(viewModel.coverageRatio * 100)
        let uncovered = viewModel.uncoveredFaces.values.reduce(0) { $0 + $1.count }
        let total = uncovered > 0 ? Int(Double(uncovered) / max(1.0 - Double(viewModel.coverageRatio), 0.001)) : 0

        return VStack(spacing: 16) {
            Text("\(pct)% Coverage")
                .font(.system(.largeTitle, design: .rounded))
                .fontWeight(.bold)

            if uncovered > 0 {
                VStack(spacing: 8) {
                    Text("\(uncovered) of \(total) mesh faces have no camera coverage")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if pct < 80 {
                        Text("Consider scanning areas you may have missed — corners, ceiling, and behind obstacles.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                }
            } else {
                Text("All mesh faces have camera coverage")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }

            // Frame count info
            Text("\(viewModel.keyframeCount) keyframes captured")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
    }

    private var controlButtons: some View {
        VStack(spacing: 16) {
            Button(action: onLooksGood) {
                Label("Looks Good — Annotate Corners", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(viewModel.isAnalyzingCoverage)

            Button(action: onContinueScanning) {
                Label("Continue Scanning", systemImage: "camera.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(uiColor: .systemGray5))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(viewModel.isAnalyzingCoverage)
        }
        .padding(.horizontal, 40)
    }
}
