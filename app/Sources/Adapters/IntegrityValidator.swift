import AVFoundation
import EverKeepCore

/// Checks the candidate against the original with the same probing code on both sides, so
/// orientation and rounding differences between PhotoKit and AVFoundation cannot cause false mismatches.
final class IntegrityValidator: ValidationPort, @unchecked Sendable {
    private let library: PhotoLibraryAdapter

    init(library: PhotoLibraryAdapter) {
        self.library = library
    }

    func validate(original: MediaAsset, candidate: URL, settings encoding: EncodingSettings) async throws -> ValidationFinding {
        guard case .video(let settings) = encoding else { throw AdapterError.unsupportedSettings }
        let encoded = AVURLAsset(url: candidate)
        let source = try await library.openAVAsset(id: original.id)
        let playable = try await encoded.load(.isPlayable)
        let encodedFacts = try await VideoFacts.read(from: encoded)
        let sourceFacts = try await VideoFacts.read(from: source)
        let sourceFrames = try await Self.readFrames(source, decode: false)
        let decoded = try await Self.readFrames(encoded, decode: true)

        guard let fileSize = try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw AdapterError.readerFailed("the candidate's file size is unavailable")
        }
        let audioMatches = encodedFacts.audioRanges.count == sourceFacts.audioRanges.count
            && zip(encodedFacts.audioRanges, sourceFacts.audioRanges).allSatisfy {
                abs($0.0.start.seconds - $0.1.start.seconds) <= 0.1
                    && abs($0.0.duration.seconds - $0.1.duration.seconds) <= 0.1
            }

        let report = IntegrityReport(
            playable: playable,
            fullyDecoded: sourceFrames.completed && decoded.completed && sourceFrames.count > 0
                && decoded.count == sourceFrames.count,
            durationDelta: abs(encodedFacts.duration - sourceFacts.duration),
            dimensionsMatch: Int(encodedFacts.displaySize.width.rounded()) == settings.width
                && Int(encodedFacts.displaySize.height.rounded()) == settings.height,
            audioTracksMatch: encodedFacts.audioTrackCount == sourceFacts.audioTrackCount && audioMatches
                && encodedFacts.trackTypes == sourceFacts.trackTypes,
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
            while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
            return (count, reader.status == .completed)
        }.value
    }
}
