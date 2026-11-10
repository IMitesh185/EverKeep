import Foundation

public struct PreservationPolicyEngine: Sendable {
    public static let version = 1

    private let rules: EligibilityRules
    private let planner: CompressionPlanner

    public init(rules: EligibilityRules = EligibilityRules(), planner: CompressionPlanner = CompressionPlanner()) {
        self.rules = rules
        self.planner = planner
    }

    /// Protection short-circuits everything. Age is never an input (ADR-0006).
    public func decide(_ asset: MediaAsset, protectedIds: Set<String>, settings: PolicySettings) -> PreservationDecision {
        if protectedIds.contains(asset.id) {
            return make(asset, .protect, [.userProtected])
        }
        if asset.isFavorite && settings.protectFavorites {
            return make(asset, .protect, [.favoriteProtected])
        }

        let eligibility = rules.evaluate(asset)
        switch eligibility {
        case .notEligible(let reason):
            return make(asset, .notEligible, [reason])
        case .deferred(.imagesDeferred):
            return make(asset, .deferred, [.imagesDeferred])
        case .deferred, .eligible:
            break
        }

        if asset.sizeBytes > 0 && asset.sizeBytes < settings.minBytes {
            return make(asset, .keepAsIs, [.tooSmall])
        }
        if case .deferred(let reason) = eligibility {
            return make(asset, .deferred, [reason])
        }

        let tier: QualityTier = asset.isFavorite ? .conservative : .standard
        guard planner.plan(for: asset, tier: tier) != nil else {
            return make(asset, .keepAsIs, [.alreadyEfficient])
        }
        if tier == .conservative {
            return make(asset, .optimizeConservatively, [.worthOptimizing, .favoriteConservative], risk: .medium, tier: tier)
        }
        return make(asset, .optimize, [.worthOptimizing], risk: .low, tier: tier)
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
