import AVFoundation
import CoreGraphics
import EverKeepCore

extension LumaFrame {
    /// Draws the image into an 8-bit gray bitmap, which converts colour to luma the same way for both sides.
    init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }
}

/// Sampled SSIM between the original and the candidate. This is a cheap proxy for VMAF (U3) and
/// stays uncalibrated until the lab maps it, so the thresholds in `QualityPolicy` are conservative.
final class QualityAssessmentEngine: ValidationPort, @unchecked Sendable {
    private let library: PhotoLibraryAdapter
    private let sampleCount = 12
    private let maxSide: CGFloat = 1920

    init(library: PhotoLibraryAdapter) {
        self.library = library
    }

    func validate(original: MediaAsset, candidate: URL, settings: EncodeSettings) async throws -> ValidationFinding {
        let source = try await library.openAVAsset(id: original.id)
        let encoded = AVURLAsset(url: candidate)
        let seconds = try await encoded.load(.duration).seconds
        guard seconds > 0 else { return ValidationFinding() }

        let sourceGenerator = makeGenerator(for: source)
        let encodedGenerator = makeGenerator(for: encoded)
        var scores: [Double] = []
        for index in 0..<sampleCount {
            try Task.checkCancellation()
            let time = CMTime(seconds: seconds * (Double(index) + 0.5) / Double(sampleCount), preferredTimescale: 600)
            let before = try await sourceGenerator.image(at: time).image
            let after = try await encodedGenerator.image(at: time).image
            guard let a = LumaFrame(cgImage: before),
                  let b = LumaFrame(cgImage: after),
                  let score = SSIM.compare(a, b) else { continue }
            scores.append(score)
        }
        guard !scores.isEmpty else { return ValidationFinding() }

        let metrics = QualityMetrics(
            meanSSIM: scores.reduce(0, +) / Double(scores.count),
            minSSIM: scores.min() ?? 0,
            framesCompared: scores.count
        )
        return ValidationFinding(quality: metrics)
    }

    private func makeGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        return generator
    }
}
