import Foundation

public struct EncodeSettings: Codable, Equatable, Sendable {
    public let bitrate: Int
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let bitsPerPixel: Double

    public init(bitrate: Int, width: Int, height: Int, frameRate: Double, bitsPerPixel: Double) {
        self.bitrate = bitrate
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitsPerPixel = bitsPerPixel
    }
}

public struct ImageEncodeSettings: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable {
        case png, jpeg, heic

        public var typeIdentifier: String {
            switch self {
            case .png: return "public.png"
            case .jpeg: return "public.jpeg"
            case .heic: return "public.heic"
            }
        }

        public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    }

    public let format: Format
    public let quality: Double
    public let width: Int
    public let height: Int

    public init(format: Format, quality: Double, width: Int, height: Int) {
        self.format = format
        self.quality = quality
        self.width = width
        self.height = height
    }
}

public enum EncodingSettings: Codable, Equatable, Sendable {
    case video(EncodeSettings)
    case image(ImageEncodeSettings)

    private enum CodingKeys: String, CodingKey { case video, image, bitrate }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.video) {
            self = .video(try values.decode(EncodeSettings.self, forKey: .video))
        } else if values.contains(.image) {
            self = .image(try values.decode(ImageEncodeSettings.self, forKey: .image))
        } else if values.contains(.bitrate) {
            self = .video(try EncodeSettings(from: decoder))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown encoding settings"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .video(let settings): try values.encode(settings, forKey: .video)
        case .image(let settings): try values.encode(settings, forKey: .image)
        }
    }

    public var videoSettings: EncodeSettings? {
        if case .video(let settings) = self { return settings }
        return nil
    }

    public var width: Int {
        switch self {
        case .video(let settings): return settings.width
        case .image(let settings): return settings.width
        }
    }

    public var height: Int {
        switch self {
        case .video(let settings): return settings.height
        case .image(let settings): return settings.height
        }
    }

    public var fileExtension: String {
        switch self {
        case .video: return "mov"
        case .image(let settings): return settings.format.fileExtension
        }
    }

    public func stagingBudget(for asset: MediaAsset) -> Int64 {
        let estimate: Double
        switch self {
        case .video(let settings): estimate = Double(settings.bitrate) * asset.duration / 8 * 1.25
        case .image: estimate = Double(asset.sizeBytes) * 1.25
        }
        guard estimate.isFinite, estimate >= 0, estimate < Double(Int64.max) else { return Int64.max }
        return Int64(estimate.rounded(.up))
    }
}

/// Candidate encodings for one item, most aggressive first. The hardware encoder may only
/// take a bitrate target (U2), so the orchestrator walks the ladder until a rung passes.
public struct CompressionPlan: Codable, Equatable, Sendable {
    public let assetId: String
    public let tier: QualityTier
    public let rungs: [EncodingSettings]
    public let mode: PreservationMode?
    public let qualityPolicyVersion: Int?

    public init(
        assetId: String,
        tier: QualityTier,
        rungs: [EncodingSettings],
        mode: PreservationMode = .almostIdentical,
        qualityPolicyVersion: Int = QualityPolicy.version
    ) {
        self.assetId = assetId
        self.tier = tier
        self.rungs = rungs
        self.mode = mode
        self.qualityPolicyVersion = qualityPolicyVersion
    }
}

/// The bits-per-pixel values are uncalibrated defaults until Experiment 0 measures real footage.
public struct PlannerConfig: Equatable, Sendable {
    public var standardBitsPerPixel: [Double] = [0.050, 0.070, 0.090]
    public var conservativeBitsPerPixel: [Double] = [0.080, 0.100, 0.120]
    public var spaceSavingBitsPerPixel: [Double] = [0.035, 0.050, 0.070]
    public var minBitrate = 400_000
    /// A rung is offered only if it is at least this much lower than the source bitrate.
    public var minSavingsFraction = 0.25

    public init() {}
}

public struct CompressionPlanner: Sendable {
    private let config: PlannerConfig

    public init(config: PlannerConfig = PlannerConfig()) {
        self.config = config
    }

    /// Returns nil when no rung is meaningfully cheaper than the source (already efficient).
    public func plan(
        for asset: MediaAsset,
        tier: QualityTier,
        mode: PreservationMode? = nil
    ) -> CompressionPlan? {
        let chosenMode = mode ?? (tier == .spaceSaving ? .spaceFirst : .almostIdentical)
        guard chosenMode.permitsOptimization, asset.pixelWidth > 0, asset.pixelHeight > 0 else { return nil }
        if asset.kind.isImage { return imagePlan(for: asset, tier: tier, mode: chosenMode) }
        guard asset.kind == .video else { return nil }
        guard let sourceBitrate = asset.bitrate, let fps = asset.frameRate,
              sourceBitrate > 0, fps.isFinite, fps > 0, asset.duration.isFinite, asset.duration > 0
        else { return nil }

        var width = asset.pixelWidth
        var height = asset.pixelHeight
        if tier == .spaceSaving, asset.contentHints?.containsText != true {
            let scale = min(1, 720 / Double(min(width, height)))
            if scale < 1 {
                width = max(2, Int((Double(width) * scale / 2).rounded()) * 2)
                height = max(2, Int((Double(height) * scale / 2).rounded()) * 2)
            }
        }
        let table: [Double]
        switch tier {
        case .standard: table = config.standardBitsPerPixel
        case .conservative: table = config.conservativeBitsPerPixel
        case .spaceSaving: table = config.spaceSavingBitsPerPixel
        }
        let motionFactor: Double
        switch asset.contentHints?.motion {
        case .some(.high): motionFactor = 1.3
        case .some(.low): motionFactor = 0.85
        case .none: motionFactor = 1
        }
        let ceiling = Double(sourceBitrate) * (1 - config.minSavingsFraction)

        var sizes = [(width, height, table)]
        if width != asset.pixelWidth || height != asset.pixelHeight {
            sizes.append((asset.pixelWidth, asset.pixelHeight, config.conservativeBitsPerPixel))
        }
        var rungs: [EncodingSettings] = []
        for (rungWidth, rungHeight, levels) in sizes {
            let pixelsPerSecond = Double(rungWidth) * Double(rungHeight) * fps
            for bitsPerPixel in levels {
                let target = pixelsPerSecond * bitsPerPixel * motionFactor
                guard target.isFinite, target >= 0, target < Double(Int.max) else { continue }
                let bitrate = max(config.minBitrate, Int(target.rounded()))
                guard Double(bitrate) <= ceiling else { continue }
                rungs.append(.video(EncodeSettings(
                    bitrate: bitrate, width: rungWidth, height: rungHeight,
                    frameRate: fps, bitsPerPixel: Double(bitrate) / pixelsPerSecond
                )))
            }
        }
        return rungs.isEmpty ? nil : CompressionPlan(assetId: asset.id, tier: tier, rungs: rungs, mode: chosenMode)
    }

    private func imagePlan(for asset: MediaAsset, tier: QualityTier, mode: PreservationMode) -> CompressionPlan? {
        guard let codec = asset.codec, EligibilityRules.supportedImageTypes.contains(codec) else { return nil }
        let textSensitive = asset.kind == .screenshot || asset.contentHints?.containsText == true
        let format: ImageEncodeSettings.Format
        if codec == "public.png" {
            format = .png
        } else {
            format = codec == "public.heic" ? .heic : .jpeg
        }
        var settings: [ImageEncodeSettings] = []
        if format == .png {
            settings.append(ImageEncodeSettings(format: .png, quality: 1, width: asset.pixelWidth, height: asset.pixelHeight))
            if asset.contentHints?.hasTransparency == true {
                return CompressionPlan(assetId: asset.id, tier: tier, rungs: settings.map { .image($0) }, mode: mode)
            }
        }
        let qualities: [Double]
        if textSensitive {
            qualities = [0.98, 0.995, 1]
        } else if tier == .spaceSaving {
            qualities = [0.70, 0.82, 0.94]
        } else {
            qualities = [0.90, 0.96, 0.995]
        }
        let lossyFormat: ImageEncodeSettings.Format = format == .png ? .heic : format
        for quality in qualities {
            settings.append(ImageEncodeSettings(
                format: lossyFormat, quality: quality, width: asset.pixelWidth, height: asset.pixelHeight
            ))
        }
        return CompressionPlan(assetId: asset.id, tier: tier, rungs: settings.map { .image($0) }, mode: mode)
    }
}
