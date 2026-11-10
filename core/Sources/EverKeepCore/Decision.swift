import Foundation

public enum Outcome: String, Codable, Sendable, CaseIterable {
    case keepAsIs, protect, optimize, optimizeConservatively, deferred, askUser, notEligible
}

public enum ReasonCode: String, Codable, Sendable {
    case userProtected, favoriteProtected
    case notOnDevice, edited, hdr, specialVideo, unsupportedCodec, unsupportedKind
    case imagesDeferred, analysisIncomplete
    case tooSmall, alreadyEfficient
    case worthOptimizing, favoriteConservative

    public var explanation: String {
        switch self {
        case .userProtected: return "You protected this item."
        case .favoriteProtected: return "Favorites are protected."
        case .notOnDevice: return "The original is not stored on this device."
        case .edited: return "It has edits that a replacement would flatten."
        case .hdr: return "HDR and wide-colour video is not supported yet."
        case .specialVideo: return "Slow motion, time-lapse, cinematic and spatial video is not supported yet."
        case .unsupportedCodec: return "Its format is not supported."
        case .unsupportedKind: return "This kind of item is not supported."
        case .imagesDeferred: return "Photos are not optimized in this version."
        case .analysisIncomplete: return "It has not been analyzed yet."
        case .tooSmall: return "Too small to be worth changing."
        case .alreadyEfficient: return "Already stored efficiently."
        case .worthOptimizing: return "Its bitrate is high enough to be worth preparing a candidate."
        case .favoriteConservative: return "Favorite: the most conservative settings apply."
        }
    }
}

public enum Risk: String, Codable, Sendable {
    case low, medium, high
}

public enum QualityTier: String, Codable, Sendable {
    case standard, conservative
}

/// Explicit protection is the only non-technical input to a decision (ADR-0006).
public struct PolicySettings: Codable, Equatable, Sendable {
    public var protectFavorites: Bool
    public var minBytes: Int64

    public init(protectFavorites: Bool = true, minBytes: Int64 = 20_000_000) {
        self.protectFavorites = protectFavorites
        self.minBytes = minBytes
    }
}

public struct PreservationDecision: Codable, Equatable, Sendable {
    public let assetId: String
    public let outcome: Outcome
    public let reasons: [ReasonCode]
    public let risk: Risk
    public let tier: QualityTier
    public let requiresApproval: Bool
    public let policyVersion: Int

    public init(
        assetId: String,
        outcome: Outcome,
        reasons: [ReasonCode],
        risk: Risk,
        tier: QualityTier,
        requiresApproval: Bool,
        policyVersion: Int
    ) {
        self.assetId = assetId
        self.outcome = outcome
        self.reasons = reasons
        self.risk = risk
        self.tier = tier
        self.requiresApproval = requiresApproval
        self.policyVersion = policyVersion
    }

    public var isCandidate: Bool { outcome == .optimize || outcome == .optimizeConservatively }

    public var explanation: String { reasons.map(\.explanation).joined(separator: " ") }
}
