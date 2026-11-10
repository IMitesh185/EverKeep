import Foundation

public enum MediaKind: String, Codable, Sendable {
    case video, photo, livePhoto, other
}

/// Technical snapshot of one library item. It never holds an invented "last viewed".
public struct MediaAsset: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var kind: MediaKind
    public var creationDate: Date?
    public var duration: TimeInterval
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var sizeBytes: Int64
    public var isFavorite: Bool
    public var isOnDevice: Bool
    public var hasAdjustments: Bool
    public var isSpecialVideo: Bool
    /// Set by analysis; nil until the media has been probed.
    public var codec: String?
    public var bitrate: Int?
    public var frameRate: Double?
    public var isHDR: Bool
    public var audioTrackCount: Int

    public init(
        id: String,
        kind: MediaKind = .video,
        creationDate: Date? = nil,
        duration: TimeInterval = 0,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        sizeBytes: Int64 = 0,
        isFavorite: Bool = false,
        isOnDevice: Bool = true,
        hasAdjustments: Bool = false,
        isSpecialVideo: Bool = false,
        codec: String? = nil,
        bitrate: Int? = nil,
        frameRate: Double? = nil,
        isHDR: Bool = false,
        audioTrackCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.creationDate = creationDate
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sizeBytes = sizeBytes
        self.isFavorite = isFavorite
        self.isOnDevice = isOnDevice
        self.hasAdjustments = hasAdjustments
        self.isSpecialVideo = isSpecialVideo
        self.codec = codec
        self.bitrate = bitrate
        self.frameRate = frameRate
        self.isHDR = isHDR
        self.audioTrackCount = audioTrackCount
    }

    public var isAnalyzed: Bool { codec != nil && bitrate != nil && frameRate != nil }
}
