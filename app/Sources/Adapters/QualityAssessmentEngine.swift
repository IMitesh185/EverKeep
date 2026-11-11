import AVFoundation
import CoreGraphics
import EverKeepCore

/// Sampled SSIM between the original and the candidate. This is a cheap proxy for VMAF (U3) and
/// stays uncalibrated until the lab maps it, so the thresholds in `QualityPolicy` are conservative.
final class QualityAssessmentEngine: ValidationPort, @unchecked Sendable {
    private let library: PhotoLibraryAdapter
    private let sampleCount = 12
    private let maxSide: CGFloat = 1920

    init(library: PhotoLibraryAdapter) {
        self.library = library
    }

    func validate(original: MediaAsset, candidate: URL, settings encoding: EncodingSettings) async throws -> ValidationFinding {
        guard case .video(let settings) = encoding else { throw AdapterError.unsupportedSettings }
        let source = try await library.openAVAsset(id: original.id)
        let encoded = AVURLAsset(url: candidate)
        let seconds = try await encoded.load(.duration).seconds
        guard seconds > 0 else { return ValidationFinding() }

        let sourceGenerator = makeGenerator(for: source)
        let encodedGenerator = makeGenerator(for: encoded)
        var scores: [Double] = []
        var previews: [Double] = []
        var details = DetailMetrics(framesChecked: 0)
        let contentSize = min(1920, max(settings.width, settings.height))
        for index in 0..<sampleCount {
            try Task.checkCancellation()
            let time = CMTime(seconds: seconds * (Double(index) + 0.5) / Double(sampleCount), preferredTimescale: 600)
            let before = try await sourceGenerator.image(at: time).image
            let after = try await encodedGenerator.image(at: time).image
            scores.append(try ImageAssessment.score(before, after, maxSide: contentSize))
            previews.append(try ImageAssessment.score(before, after, maxSide: 320))
            details = ImageAssessment.merge(details, try ImageAssessment.details(before, after))
        }
        guard !scores.isEmpty else { return ValidationFinding() }

        return ValidationFinding(
            quality: try ImageAssessment.metrics(scores),
            preview: try ImageAssessment.metrics(previews),
            details: details
        )
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
