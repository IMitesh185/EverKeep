import Foundation

public enum MediaKind: String, Codable, Sendable {
    case video, photo, screenshot, livePhoto, other

    public var isImage: Bool { self == .photo || self == .screenshot }
}

public struct ContentHints: Codable, Equatable, Sendable {
    public enum Motion: String, Codable, Sendable { case low, high }

    public var containsText: Bool
    public var containsFaces: Bool
    public var hasTransparency: Bool
    public var motion: Motion?

    public init(
        containsText: Bool = false,
        containsFaces: Bool = false,
        hasTransparency: Bool = false,
        motion: Motion? = nil
    ) {
        self.containsText = containsText
        self.containsFaces = containsFaces
        self.hasTransparency = hasTransparency
        self.motion = motion
    }
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
    public var modificationDate: Date?
    public var contentHints: ContentHints?
    public var analysisError: String?
    public var isSpecialPhoto: Bool?

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
        audioTrackCount: Int = 0,
        modificationDate: Date? = nil,
        contentHints: ContentHints? = nil,
        analysisError: String? = nil,
        isSpecialPhoto: Bool? = nil
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
        self.modificationDate = modificationDate
        self.contentHints = contentHints
        self.analysisError = analysisError
        self.isSpecialPhoto = isSpecialPhoto
    }

    public var isAnalyzed: Bool {
        guard codec != nil, analysisError == nil else { return false }
        if isHDR || isSpecialVideo || isSpecialPhoto == true { return true }
        guard contentHints != nil else { return false }
        return kind.isImage || (kind == .video && bitrate != nil && frameRate != nil)
    }

    public func matchesSnapshot(_ other: MediaAsset) -> Bool {
        id == other.id && kind == other.kind && modificationDate == other.modificationDate
            && (other.sizeBytes == 0 || sizeBytes == other.sizeBytes) && duration == other.duration
            && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
            && hasAdjustments == other.hasAdjustments && !other.isSpecialVideo
            && other.isSpecialPhoto != true && !other.isHDR && isFavorite == other.isFavorite
    }
}
