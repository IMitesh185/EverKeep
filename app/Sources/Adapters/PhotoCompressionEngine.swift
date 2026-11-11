import EverKeepCore
import Foundation
import ImageIO

final class PhotoCompressionEngine: CodecPort, ValidationPort, @unchecked Sendable {
    private let library: PhotoLibraryAdapter

    init(library: PhotoLibraryAdapter) {
        self.library = library
    }

    func encode(
        assetId: String,
        settings encoding: EncodingSettings,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> EncodeResult {
        guard case .image(let settings) = encoding else { throw AdapterError.unsupportedSettings }
        let document = try ImageDocument(data: await library.openImageData(id: assetId))
        guard !document.isHDR, !document.hasAuxiliaryData,
              EligibilityRules.supportedImageTypes.contains(document.typeIdentifier) else {
            throw AdapterError.unsupportedSettings
        }
        guard settings.quality.isFinite, (0...1).contains(settings.quality),
              !document.hasTransparency || settings.format == .png,
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, settings.format.typeIdentifier as CFString, 1, nil
              ) else { throw AdapterError.unsupportedSettings }
        try Task.checkCancellation()
        var properties = document.properties
        if settings.format != .png {
            properties[kCGImageDestinationLossyCompressionQuality as String] = settings.quality
        }
        CGImageDestinationAddImage(destination, document.image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AdapterError.imageFailed("the candidate could not be written")
        }
        try Task.checkCancellation()
        progress(1)
        return EncodeResult(bytes: try Self.fileSize(url))
    }

    func validate(original: MediaAsset, candidate: URL, settings encoding: EncodingSettings) async throws -> ValidationFinding {
        guard case .image(let settings) = encoding else { throw AdapterError.unsupportedSettings }
        let before = try ImageDocument(data: await library.openImageData(id: original.id))
        let after = try ImageDocument(data: Data(contentsOf: candidate))
        let source = try before.rendered(maxSide: max(original.pixelWidth, original.pixelHeight))
        let encoded = try after.rendered(maxSide: max(settings.width, settings.height))
        let contentSize = original.kind == .screenshot || original.contentHints?.containsText == true
            ? max(source.width, source.height) : 1920
        let quality = try ImageAssessment.score(source, encoded, maxSide: contentSize)
        let preview = try ImageAssessment.score(source, encoded, maxSide: 320)
        let details = try ImageAssessment.details(source, encoded)
        let report = IntegrityReport(
            playable: true,
            fullyDecoded: true,
            durationDelta: 0,
            dimensionsMatch: encoded.width == settings.width && encoded.height == settings.height
                && source.width == encoded.width && source.height == encoded.height,
            audioTracksMatch: true,
            frameRateDelta: 0,
            colorMatches: !before.isHDR && !after.isHDR && before.hasTransparency == after.hasTransparency,
            isHDR: after.isHDR,
            candidateBytes: try Self.fileSize(candidate)
        )
        return ValidationFinding(
            integrity: report,
            quality: try ImageAssessment.metrics([quality]),
            preview: try ImageAssessment.metrics([preview]),
            details: details
        )
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        guard let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0 else {
            throw AdapterError.imageFailed("the candidate has no readable file size")
        }
        return Int64(bytes)
    }
}
