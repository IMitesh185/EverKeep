import AVFoundation
import EverKeepCore

/// Checks the candidate against the original with the same probing code on both sides, so
/// orientation and rounding differences between PhotoKit and AVFoundation cannot cause false mismatches.
final class IntegrityValidator: ValidationPort, @unchecked Sendable {
    private let library: PhotoLibraryAdapter

    init(library: PhotoLibraryAdapter) {
        self.library = library
    }

    func validate(original: MediaAsset, candidate: URL, settings: EncodeSettings) async throws -> ValidationFinding {
        let encoded = AVURLAsset(url: candidate)
        let source = try await library.openAVAsset(id: original.id)
        let playable = try await encoded.load(.isPlayable)
        let encodedFacts = try await VideoFacts.read(from: encoded)
        let sourceFacts = try await VideoFacts.read(from: source)
        let sourceFrames = try await Self.readFrames(source, decode: false)
        let decoded = try await Self.readFrames(encoded, decode: true)

        let tolerance = max(2, sourceFrames.count / 100)
        let fileSize = (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        let report = IntegrityReport(
            playable: playable,
            fullyDecoded: decoded.completed && abs(decoded.count - sourceFrames.count) <= tolerance,
            durationDelta: abs(encodedFacts.duration - sourceFacts.duration),
            dimensionsMatch: encodedFacts.displaySize == sourceFacts.displaySize,
            audioTracksMatch: encodedFacts.audioTrackCount == sourceFacts.audioTrackCount,
            frameRateDelta: abs(encodedFacts.frameRate - sourceFacts.frameRate),
            colorMatches: encodedFacts.colorTags == sourceFacts.colorTags,
            isHDR: encodedFacts.isHDR,
            candidateBytes: Int64(fileSize)
        )
        return ValidationFinding(integrity: report)
    }

    /// Reads every video sample off the cooperative pool. Decoding is the integrity check for the candidate;
    /// the source is only counted, which does not need a decoder. A read error leaves `completed` false.
    private static func readFrames(_ asset: AVAsset, decode: Bool) async throws -> (count: Int, completed: Bool) {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return (0, false) }
        return await Task.detached(priority: .utility) { () -> (count: Int, completed: Bool) in
            guard let reader = try? AVAssetReader(asset: asset) else { return (0, false) }
            let pixelFormat: [String: Any]? = decode
                ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                : nil
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: pixelFormat)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return (0, false) }
            reader.add(output)
            guard reader.startReading() else { return (0, false) }
            var count = 0
            while output.copyNextSampleBuffer() != nil { count += 1 }
            return (count, reader.status == .completed)
        }.value
    }
}
