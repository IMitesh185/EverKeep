import AVFoundation
import CoreMedia
import EverKeepCore
import VideoToolbox

/// Throttles progress callbacks from the sample-copy loop.
private final class ProgressGate: @unchecked Sendable {
    var last = -1.0
}

/// HEVC re-encode through AVAssetWriter, so the system's hardware encoder is used where it exists.
/// Resolution, frame rate, orientation, audio and container metadata are carried over unchanged.
final class VideoCompressionEngine: CodecPort, @unchecked Sendable {
    private let library: PhotoLibraryAdapter

    init(library: PhotoLibraryAdapter) {
        self.library = library
    }

    func encode(
        assetId: String,
        settings: EncodeSettings,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> EncodeResult {
        let asset = try await library.openAVAsset(id: assetId)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AdapterError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration).seconds
        let metadata = try await asset.load(.metadata)

        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = metadata

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(settings.frameRate.rounded()),
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(naturalSize.width),
            AVVideoHeightKey: Int(naturalSize.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw AdapterError.unsupportedSettings
        }

        let pixelFormat: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: pixelFormat)
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
            throw AdapterError.readerFailed("the video track cannot be copied")
        }
        reader.add(videoOutput)
        writer.add(videoInput)

        var pairs: [(output: AVAssetReaderOutput, input: AVAssetWriterInput)] = [(output: videoOutput, input: videoInput)]
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            let hint = descriptions.first.map { $0 as! CMFormatDescription }
            let audioOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            audioInput.expectsMediaDataInRealTime = false
            guard reader.canAdd(audioOutput), writer.canAdd(audioInput) else {
                throw AdapterError.readerFailed("an audio track cannot be copied")
            }
            reader.add(audioOutput)
            writer.add(audioInput)
            pairs.append((output: audioOutput, input: audioInput))
        }

        guard reader.startReading() else {
            throw AdapterError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.startWriting() else {
            throw AdapterError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "dev.sidequest.everkeep.encode", attributes: .concurrent)
        let activePairs = pairs
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for (index, pair) in activePairs.enumerated() {
                    group.addTask {
                        await Self.pump(
                            output: pair.output,
                            input: pair.input,
                            queue: queue,
                            duration: index == 0 ? duration : 0,
                            progress: progress
                        )
                    }
                }
            }
        } onCancel: {
            reader.cancelReading()
        }

        if Task.isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw AdapterError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw AdapterError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }

        progress(1)
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return EncodeResult(bytes: bytes)
    }

    /// Copies samples from one reader output to one writer input until the output is drained.
    private static func pump(
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        queue: DispatchQueue,
        duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async {
        let gate = ProgressGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if duration > 0 {
                        let fraction = min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)
                        if fraction - gate.last >= 0.02 {
                            gate.last = fraction
                            progress(fraction)
                        }
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
