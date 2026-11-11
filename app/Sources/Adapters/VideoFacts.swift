import AVFoundation
import CoreMedia
import EverKeepCore

enum AdapterError: Error, CustomStringConvertible {
    case assetMissing(String)
    case notOnDevice(String)
    case noVideoTrack
    case unsupportedSettings
    case readerFailed(String)
    case writerFailed(String)
    case placementFailed(String)
    case catalogue(String)
    case imageFailed(String)

    var description: String {
        switch self {
        case .assetMissing(let id): return "the library item \(id) no longer exists"
        case .notOnDevice(let id): return "the original of \(id) is not stored on this device"
        case .noVideoTrack: return "the file has no video track"
        case .unsupportedSettings: return "this device cannot write the requested HEVC settings"
        case .readerFailed(let reason): return "reading the source failed: \(reason)"
        case .writerFailed(let reason): return "writing the candidate failed: \(reason)"
        case .placementFailed(let reason): return "adding the replacement to Photos failed: \(reason)"
        case .catalogue(let reason): return "the catalogue failed: \(reason)"
        case .imageFailed(let reason): return "the image could not be processed: \(reason)"
        }
    }
}

/// Technical facts read from a video file, shared by analysis and integrity checks.
struct VideoFacts {
    var codec: String
    var bitrate: Int
    var frameRate: Double
    var displaySize: CGSize
    var duration: Double
    var isHDR: Bool
    var isSpatial: Bool
    var colorTags: String
    var audioTrackCount: Int
    var audioRanges: [CMTimeRange]
    var colorProperties: [String: String]
    var trackTypes: [String]

    static func read(from asset: AVAsset) async throws -> VideoFacts {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            throw AdapterError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioRanges: [CMTimeRange] = []
        for audio in audioTracks { audioRanges.append(try await audio.load(.timeRange)) }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let dataRate = try await track.load(.estimatedDataRate)
        let frameRate = try await track.load(.nominalFrameRate)
        let descriptions = try await track.load(.formatDescriptions)
        let duration = try await asset.load(.duration).seconds
        guard let first = descriptions.first else { throw AdapterError.noVideoTrack }
        let description = first
        let allTracks = try await asset.load(.tracks)

        let extensions = (CMFormatDescriptionGetExtensions(description) as? [String: Any]) ?? [:]
        let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String ?? ""
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? ""
        let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String ?? ""
        let hdrTransfers = [
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
        ]
        let wide = kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
        let oriented = naturalSize.applying(transform)
        var colorProperties: [String: String] = [:]
        if !primaries.isEmpty { colorProperties[AVVideoColorPrimariesKey] = primaries }
        if !transfer.isEmpty { colorProperties[AVVideoTransferFunctionKey] = transfer }
        if !matrix.isEmpty { colorProperties[AVVideoYCbCrMatrixKey] = matrix }

        return VideoFacts(
            codec: fourCC(CMFormatDescriptionGetMediaSubType(description)),
            bitrate: Int(dataRate),
            frameRate: Double(frameRate),
            displaySize: CGSize(width: abs(oriented.width), height: abs(oriented.height)),
            duration: duration,
            isHDR: hdrTransfers.contains(transfer) || primaries == wide,
            isSpatial: videoTracks.count != 1 || extensions.keys.contains { $0.contains("StereoEye") },
            colorTags: "\(primaries)|\(transfer)|\(matrix)",
            audioTrackCount: audioTracks.count,
            audioRanges: audioRanges,
            colorProperties: colorProperties,
            trackTypes: allTracks.map { $0.mediaType.rawValue }.sorted()
        )
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
