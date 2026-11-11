import EverKeepCore
import Foundation

final class MediaProcessingEngine: CodecPort, ValidationPort, @unchecked Sendable {
    private let video: VideoCompressionEngine
    private let photos: PhotoCompressionEngine
    private let integrity: IntegrityValidator
    private let quality: QualityAssessmentEngine

    init(library: PhotoLibraryAdapter) {
        video = VideoCompressionEngine(library: library)
        photos = PhotoCompressionEngine(library: library)
        integrity = IntegrityValidator(library: library)
        quality = QualityAssessmentEngine(library: library)
    }

    func encode(
        assetId: String,
        settings: EncodingSettings,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> EncodeResult {
        switch settings {
        case .video: return try await video.encode(assetId: assetId, settings: settings, to: url, progress: progress)
        case .image: return try await photos.encode(assetId: assetId, settings: settings, to: url, progress: progress)
        }
    }

    func validate(original: MediaAsset, candidate: URL, settings: EncodingSettings) async throws -> ValidationFinding {
        switch settings {
        case .video:
            let checked = try await integrity.validate(original: original, candidate: candidate, settings: settings)
            return checked.merged(with: try await quality.validate(original: original, candidate: candidate, settings: settings))
        case .image:
            return try await photos.validate(original: original, candidate: candidate, settings: settings)
        }
    }
}
