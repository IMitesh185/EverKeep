import XCTest
@testable import EverKeepCore

final class PolicyTests: XCTestCase {
    private let engine = PreservationPolicyEngine()

    private func decide(
        _ asset: MediaAsset,
        protectedIds: Set<String> = [],
        settings: PolicySettings = PolicySettings()
    ) -> PreservationDecision {
        engine.decide(asset, protectedIds: protectedIds, settings: settings)
    }

    func testHighBitrateVideoIsOptimized() {
        let decision = decide(makeAsset())
        XCTAssertEqual(decision.outcome, .optimize)
        XCTAssertEqual(decision.tier, .standard)
        XCTAssertTrue(decision.requiresApproval)
        XCTAssertTrue(decision.isCandidate)
        XCTAssertEqual(decision.policyVersion, PreservationPolicyEngine.version)
    }

    func testUserProtectionShortCircuitsEverything() {
        let decision = decide(makeAsset(), protectedIds: ["a1"])
        XCTAssertEqual(decision.outcome, .protect)
        XCTAssertEqual(decision.reasons, [.userProtected])
        XCTAssertFalse(decision.requiresApproval)
    }

    func testFavoritesAreProtectedByDefault() {
        XCTAssertEqual(decide(makeAsset(favorite: true)).outcome, .protect)
    }

    func testUnprotectedFavoritesGetTheConservativeTier() {
        let decision = decide(makeAsset(favorite: true), settings: PolicySettings(protectFavorites: false))
        XCTAssertEqual(decision.outcome, .optimizeConservatively)
        XCTAssertEqual(decision.tier, .conservative)
        XCTAssertEqual(decision.risk, .medium)
    }

    func testPhotosAreDeferred() {
        var photo = makeAsset()
        photo.kind = .photo
        XCTAssertEqual(decide(photo).outcome, .deferred)
        XCTAssertEqual(decide(photo).reasons, [.imagesDeferred])
    }

    func testUnsupportedItemsAreNotEligible() {
        var hdr = makeAsset()
        hdr.isHDR = true
        var special = makeAsset()
        special.isSpecialVideo = true
        var edited = makeAsset()
        edited.hasAdjustments = true
        var cloud = makeAsset()
        cloud.isOnDevice = false

        XCTAssertEqual(decide(hdr).reasons, [.hdr])
        XCTAssertEqual(decide(special).reasons, [.specialVideo])
        XCTAssertEqual(decide(edited).reasons, [.edited])
        XCTAssertEqual(decide(cloud).reasons, [.notOnDevice])
        XCTAssertEqual(decide(makeAsset(codec: "apcn")).reasons, [.unsupportedCodec])
        for asset in [hdr, special, edited, cloud] {
            XCTAssertEqual(decide(asset).outcome, .notEligible)
        }
    }

    func testUnanalyzedVideoIsDeferred() {
        let decision = decide(makeAsset(bitrate: nil, fps: nil, codec: nil))
        XCTAssertEqual(decision.outcome, .deferred)
        XCTAssertEqual(decision.reasons, [.analysisIncomplete])
    }

    func testSmallVideoIsKeptWithoutAnalysis() {
        let decision = decide(makeAsset(size: 1_000_000, bitrate: nil, fps: nil, codec: nil))
        XCTAssertEqual(decision.outcome, .keepAsIs)
        XCTAssertEqual(decision.reasons, [.tooSmall])
    }

    func testAlreadyEfficientVideoIsKept() {
        let decision = decide(makeAsset(bitrate: 3_000_000))
        XCTAssertEqual(decision.outcome, .keepAsIs)
        XCTAssertEqual(decision.reasons, [.alreadyEfficient])
    }

    func testDecisionExplainsItself() {
        XCTAssertFalse(decide(makeAsset()).explanation.isEmpty)
    }
}

final class PlannerTests: XCTestCase {
    private let planner = CompressionPlanner()

    func testPlanOffersAscendingRungsBelowTheSource() throws {
        let plan = try XCTUnwrap(planner.plan(for: makeAsset(), tier: .standard))
        XCTAssertEqual(plan.rungs.map(\.bitrate), [3_110_400, 4_354_560, 5_598_720])
        XCTAssertEqual(plan.assetId, "a1")
    }

    func testRungsAboveTheSavingsCeilingAreDropped() throws {
        let plan = try XCTUnwrap(planner.plan(for: makeAsset(bitrate: 5_000_000), tier: .standard))
        XCTAssertEqual(plan.rungs.map(\.bitrate), [3_110_400])
    }

    func testNoPlanWhenTheSourceIsAlreadyLow() {
        XCTAssertNil(planner.plan(for: makeAsset(bitrate: 3_000_000), tier: .standard))
    }

    func testNoPlanWithoutAnalysis() {
        XCTAssertNil(planner.plan(for: makeAsset(bitrate: nil, fps: nil, codec: nil), tier: .standard))
    }

    func testConservativeTierStartsHigher() throws {
        let plan = try XCTUnwrap(planner.plan(for: makeAsset(), tier: .conservative))
        XCTAssertEqual(plan.rungs.first?.bitrate, 4_976_640)
    }
}
