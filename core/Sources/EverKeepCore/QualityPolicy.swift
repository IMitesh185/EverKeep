import Foundation

public struct QualityMetrics: Codable, Equatable, Sendable {
    public var meanSSIM: Double
    public var minSSIM: Double
    public var framesCompared: Int

    public init(meanSSIM: Double, minSSIM: Double, framesCompared: Int) {
        self.meanSSIM = meanSSIM
        self.minSSIM = minSSIM
        self.framesCompared = framesCompared
    }
}

public struct IntegrityReport: Codable, Equatable, Sendable {
    public var playable: Bool
    public var fullyDecoded: Bool
    public var durationDelta: Double
    public var dimensionsMatch: Bool
    public var audioTracksMatch: Bool
    public var frameRateDelta: Double
    public var colorMatches: Bool
    public var isHDR: Bool
    public var candidateBytes: Int64

    public init(
        playable: Bool,
        fullyDecoded: Bool,
        durationDelta: Double,
        dimensionsMatch: Bool,
        audioTracksMatch: Bool,
        frameRateDelta: Double,
        colorMatches: Bool,
        isHDR: Bool,
        candidateBytes: Int64
    ) {
        self.playable = playable
        self.fullyDecoded = fullyDecoded
        self.durationDelta = durationDelta
        self.dimensionsMatch = dimensionsMatch
        self.audioTracksMatch = audioTracksMatch
        self.frameRateDelta = frameRateDelta
        self.colorMatches = colorMatches
        self.isHDR = isHDR
        self.candidateBytes = candidateBytes
    }
}

/// Each validator fills the part it knows; the orchestrator merges them.
public struct ValidationFinding: Codable, Equatable, Sendable {
    public var integrity: IntegrityReport?
    public var quality: QualityMetrics?

    public init(integrity: IntegrityReport? = nil, quality: QualityMetrics? = nil) {
        self.integrity = integrity
        self.quality = quality
    }

    public func merged(with other: ValidationFinding) -> ValidationFinding {
        ValidationFinding(integrity: other.integrity ?? integrity, quality: other.quality ?? quality)
    }
}

public enum QualityFailure: String, Codable, Sendable {
    case integrityMissing, qualityMissing, originalSizeUnknown
    case notPlayable, decodeFailed, durationMismatch, dimensionsMismatch, audioMismatch
    case frameRateMismatch, colorMismatch, becameHDR
    case notSmaller, belowMinimumSavings
    case tooFewFrames, meanSSIMTooLow, minSSIMTooLow
}

public enum QualityVerdict: Equatable, Sendable {
    case pass
    case fail([QualityFailure])
}

/// Fail-closed (ADR-0004): every required check must have run and passed.
/// The SSIM thresholds are uncalibrated defaults until the lab maps them to VMAF (U3).
public struct QualityPolicy: Equatable, Sendable {
    public static let version = 1

    public struct Thresholds: Equatable, Sendable {
        public var meanSSIM: Double
        public var minSSIM: Double
        public var minFrames: Int
        public var maxDurationDelta: Double
        public var maxFrameRateDelta: Double
        public var minSavingsFraction: Double

        public init(
            meanSSIM: Double,
            minSSIM: Double,
            minFrames: Int = 8,
            maxDurationDelta: Double = 0.1,
            maxFrameRateDelta: Double = 0.5,
            minSavingsFraction: Double = 0.1
        ) {
            self.meanSSIM = meanSSIM
            self.minSSIM = minSSIM
            self.minFrames = minFrames
            self.maxDurationDelta = maxDurationDelta
            self.maxFrameRateDelta = maxFrameRateDelta
            self.minSavingsFraction = minSavingsFraction
        }
    }

    public var standard: Thresholds
    public var conservative: Thresholds

    public init(
        standard: Thresholds = Thresholds(meanSSIM: 0.985, minSSIM: 0.95),
        conservative: Thresholds = Thresholds(meanSSIM: 0.992, minSSIM: 0.97)
    ) {
        self.standard = standard
        self.conservative = conservative
    }

    public func evaluate(finding: ValidationFinding, originalBytes: Int64, tier: QualityTier) -> QualityVerdict {
        let limits = tier == .conservative ? conservative : standard
        var failures: [QualityFailure] = []

        if let report = finding.integrity {
            if !report.playable { failures.append(.notPlayable) }
            if !report.fullyDecoded { failures.append(.decodeFailed) }
            if report.durationDelta > limits.maxDurationDelta { failures.append(.durationMismatch) }
            if !report.dimensionsMatch { failures.append(.dimensionsMismatch) }
            if !report.audioTracksMatch { failures.append(.audioMismatch) }
            if report.frameRateDelta > limits.maxFrameRateDelta { failures.append(.frameRateMismatch) }
            if !report.colorMatches { failures.append(.colorMismatch) }
            if report.isHDR { failures.append(.becameHDR) }
            if originalBytes <= 0 {
                failures.append(.originalSizeUnknown)
            } else if report.candidateBytes >= originalBytes {
                failures.append(.notSmaller)
            } else if Double(originalBytes - report.candidateBytes) / Double(originalBytes) < limits.minSavingsFraction {
                failures.append(.belowMinimumSavings)
            }
        } else {
            failures.append(.integrityMissing)
        }

        if let metrics = finding.quality {
            if metrics.framesCompared < limits.minFrames { failures.append(.tooFewFrames) }
            if metrics.meanSSIM < limits.meanSSIM { failures.append(.meanSSIMTooLow) }
            if metrics.minSSIM < limits.minSSIM { failures.append(.minSSIMTooLow) }
        } else {
            failures.append(.qualityMissing)
        }

        return failures.isEmpty ? .pass : .fail(failures)
    }
}
