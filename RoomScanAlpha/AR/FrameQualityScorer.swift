// Scores captured keyframes on sharpness (Laplacian variance) and feature density
// (corner detection). Used post-scan to select the best 180 frames from ~250 captured.

import Accelerate
import UIKit

struct FrameQualityScorer {

    /// Weights for the composite score.
    static let sharpnessWeight: Float = 0.5
    static let featureDensityWeight: Float = 0.5

    /// Target number of frames to keep after post-scan selection.
    static let targetFrameCount = 180

    /// Composite quality score for a captured frame's JPEG data. Returns 0–1.
    static func score(jpegData: Data) -> Float {
        guard let uiImage = UIImage(data: jpegData),
              let cgImage = uiImage.cgImage else {
            return 0
        }

        let grayscale = grayscalePixels(from: cgImage)
        let width = cgImage.width
        let height = cgImage.height

        let sharpness = laplacianVariance(pixels: grayscale, width: width, height: height)
        let features = featureDensity(pixels: grayscale, width: width, height: height)

        return sharpness * sharpnessWeight + features * featureDensityWeight
    }

    // MARK: - Sharpness via Laplacian Variance

    /// Compute the variance of a 3x3 Laplacian-filtered image. High variance = sharp.
    /// Normalized to 0–1 using a sigmoid-like mapping calibrated for typical indoor JPEGs.
    static func laplacianVariance(pixels: [Float], width: Int, height: Int) -> Float {
        guard width > 2, height > 2 else { return 0 }

        let count = width * height
        var output = [Float](repeating: 0, count: count)

        // 3x3 Laplacian kernel: [0, 1, 0, 1, -4, 1, 0, 1, 0]
        let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]

        pixels.withUnsafeBufferPointer { srcBuf in
            output.withUnsafeMutableBufferPointer { dstBuf in
                vDSP_imgfir(
                    srcBuf.baseAddress!, vDSP_Length(height), vDSP_Length(width),
                    kernel,
                    dstBuf.baseAddress!,
                    3, 3
                )
            }
        }

        // Variance of the Laplacian response
        var mean: Float = 0
        var meanSq: Float = 0
        vDSP_meanv(output, 1, &mean, vDSP_Length(count))
        vDSP_measqv(output, 1, &meanSq, vDSP_Length(count))
        let variance = meanSq - mean * mean

        // Normalize: sigmoid mapping. Variance of ~200 maps to ~0.5; >800 saturates near 1.0.
        // Calibrated for grayscale Laplacian variance across typical indoor JPEG keyframes.
        let normalized = 1.0 / (1.0 + exp(-0.008 * (variance - 200)))
        return max(0, min(1, normalized))
    }

    // MARK: - Feature Density via Harris-like Corner Response

    /// Approximate corner/feature density using gradient magnitude.
    /// Counts pixels where gradient magnitude exceeds a threshold, normalized by image area.
    static func featureDensity(pixels: [Float], width: Int, height: Int) -> Float {
        guard width > 2, height > 2 else { return 0 }

        let count = width * height

        // Horizontal gradient (Sobel-like: [-1, 0, 1])
        var gx = [Float](repeating: 0, count: count)
        let kernelH: [Float] = [-1, 0, 1]
        pixels.withUnsafeBufferPointer { srcBuf in
            gx.withUnsafeMutableBufferPointer { dstBuf in
                vDSP_imgfir(
                    srcBuf.baseAddress!, vDSP_Length(height), vDSP_Length(width),
                    kernelH,
                    dstBuf.baseAddress!,
                    1, 3
                )
            }
        }

        // Vertical gradient
        var gy = [Float](repeating: 0, count: count)
        let kernelV: [Float] = [-1, 0, 1]
        pixels.withUnsafeBufferPointer { srcBuf in
            gy.withUnsafeMutableBufferPointer { dstBuf in
                vDSP_imgfir(
                    srcBuf.baseAddress!, vDSP_Length(height), vDSP_Length(width),
                    kernelV,
                    dstBuf.baseAddress!,
                    3, 1
                )
            }
        }

        // Gradient magnitude: sqrt(gx^2 + gy^2)
        var gxSq = [Float](repeating: 0, count: count)
        var gySq = [Float](repeating: 0, count: count)
        vDSP_vsq(gx, 1, &gxSq, 1, vDSP_Length(count))
        vDSP_vsq(gy, 1, &gySq, 1, vDSP_Length(count))

        var magSq = [Float](repeating: 0, count: count)
        vDSP_vadd(gxSq, 1, gySq, 1, &magSq, 1, vDSP_Length(count))

        // Count pixels above threshold (strong features).
        // Threshold tuned for normalized 0-1 grayscale: 0.01 magnitude² ≈ 0.1 gradient.
        let threshold: Float = 0.01
        let featureCount = magSq.reduce(0) { $0 + ($1 > threshold ? 1 : 0) }

        // Normalize: fraction of pixels that are "feature" pixels.
        // Typical indoor scene: 5-20% of pixels are features.
        // Map so that ~10% features → 0.5, ~20%+ → ~1.0
        let fraction = Float(featureCount) / Float(count)
        let normalized = min(1.0, fraction / 0.20)
        return max(0, normalized)
    }

    // MARK: - Grayscale Conversion

    /// Convert a CGImage to a row-major Float array of grayscale pixel values (0–1).
    static func grayscalePixels(from cgImage: CGImage) -> [Float] {
        let width = cgImage.width
        let height = cgImage.height
        let count = width * height

        // Render into an 8-bit grayscale buffer
        var grayBytes = [UInt8](repeating: 0, count: count)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &grayBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return [Float](repeating: 0, count: count)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert UInt8 → Float (0–1)
        var floatPixels = [Float](repeating: 0, count: count)
        vDSP_vfltu8(grayBytes, 1, &floatPixels, 1, vDSP_Length(count))
        var divisor: Float = 255.0
        vDSP_vsdiv(floatPixels, 1, &divisor, &floatPixels, 1, vDSP_Length(count))

        return floatPixels
    }
}
