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

/// Candidate encodings for one item, most aggressive first. The hardware encoder may only
/// take a bitrate target (U2), so the orchestrator walks the ladder until a rung passes.
public struct CompressionPlan: Codable, Equatable, Sendable {
    public let assetId: String
    public let tier: QualityTier
    public let rungs: [EncodeSettings]

    public init(assetId: String, tier: QualityTier, rungs: [EncodeSettings]) {
        self.assetId = assetId
        self.tier = tier
        self.rungs = rungs
    }
}

/// The bits-per-pixel values are uncalibrated defaults until Experiment 0 measures real footage.
public struct PlannerConfig: Equatable, Sendable {
    public var standardBitsPerPixel: [Double] = [0.050, 0.070, 0.090]
    public var conservativeBitsPerPixel: [Double] = [0.080, 0.100, 0.120]
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
    public func plan(for asset: MediaAsset, tier: QualityTier) -> CompressionPlan? {
        guard let sourceBitrate = asset.bitrate, let fps = asset.frameRate,
              sourceBitrate > 0, fps > 0, asset.pixelWidth > 0, asset.pixelHeight > 0
        else { return nil }

        let pixelsPerSecond = Double(asset.pixelWidth * asset.pixelHeight) * fps
        let table = tier == .conservative ? config.conservativeBitsPerPixel : config.standardBitsPerPixel
        let ceiling = Double(sourceBitrate) * (1 - config.minSavingsFraction)

        var rungs: [EncodeSettings] = []
        for bitsPerPixel in table {
            let bitrate = max(config.minBitrate, Int((pixelsPerSecond * bitsPerPixel).rounded()))
            guard Double(bitrate) <= ceiling else { continue }
            rungs.append(EncodeSettings(
                bitrate: bitrate,
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                frameRate: fps,
                bitsPerPixel: bitsPerPixel
            ))
        }
        return rungs.isEmpty ? nil : CompressionPlan(assetId: asset.id, tier: tier, rungs: rungs)
    }
}
