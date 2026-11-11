import Foundation

public struct PreservationPolicyEngine: Sendable {
    public static let version = 2

    private let rules: EligibilityRules
    private let planner: CompressionPlanner

    public init(rules: EligibilityRules = EligibilityRules(), planner: CompressionPlanner = CompressionPlanner()) {
        self.rules = rules
        self.planner = planner
    }

    /// Protection short-circuits everything. Age is never an input (ADR-0006).
    public func decide(
        _ asset: MediaAsset,
        protectedIds: Set<String>,
        settings: PolicySettings,
        mode: PreservationMode = .undecided
    ) -> PreservationDecision {
        if protectedIds.contains(asset.id) || mode == .protected {
            return make(asset, .protect, [.userProtected])
        }
        if asset.isFavorite && settings.protectFavorites && !mode.permitsOptimization {
            return make(asset, .protect, [.favoriteProtected])
        }

        let eligibility = rules.evaluate(asset)
        switch eligibility {
        case .notEligible(let reason):
            return make(asset, .notEligible, [reason])
        case .deferred(.livePhotosDeferred):
            return make(asset, .deferred, [.livePhotosDeferred])
        case .deferred, .eligible:
            break
        }

        if asset.sizeBytes > 0 && asset.sizeBytes < settings.minimumBytes(for: asset.kind) {
            return make(asset, .keepAsIs, [.tooSmall])
        }
        guard mode.permitsOptimization else { return make(asset, .askUser, [.modeRequired]) }
        if case .deferred(let reason) = eligibility {
            return make(asset, .deferred, [reason])
        }

        let tier = mode.tier
        guard planner.plan(for: asset, tier: tier, mode: mode) != nil else {
            return make(asset, .keepAsIs, [.alreadyEfficient])
        }
        if tier == .conservative {
            let reasons: [ReasonCode] = asset.isFavorite ? [.worthOptimizing, .favoriteConservative] : [.worthOptimizing]
            return make(asset, .optimizeConservatively, reasons, tier: tier)
        }
        return make(asset, .optimize, [.worthOptimizing, .spaceFirstSelected], risk: .medium, tier: tier)
    }

    private func make(
        _ asset: MediaAsset,
        _ outcome: Outcome,
        _ reasons: [ReasonCode],
        risk: Risk = .low,
        tier: QualityTier = .standard
    ) -> PreservationDecision {
        PreservationDecision(
            assetId: asset.id,
            outcome: outcome,
            reasons: reasons,
            risk: risk,
            tier: tier,
            requiresApproval: outcome == .optimize || outcome == .optimizeConservatively,
            policyVersion: Self.version
        )
    }
}
