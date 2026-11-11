import XCTest
@testable import EverKeepCore

final class PolicyTests: XCTestCase {
    private let engine = PreservationPolicyEngine()

    private func decide(
        _ asset: MediaAsset,
        protectedIds: Set<String> = [],
        settings: PolicySettings = PolicySettings(),
        mode: PreservationMode = .almostIdentical
    ) -> PreservationDecision {
        engine.decide(asset, protectedIds: protectedIds, settings: settings, mode: mode)
    }

    func testHighBitrateVideoIsOptimized() {
        let decision = decide(makeAsset())
        XCTAssertEqual(decision.outcome, .optimizeConservatively)
        XCTAssertEqual(decision.tier, .conservative)
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
        XCTAssertEqual(decide(makeAsset(favorite: true), mode: .undecided).outcome, .protect)
    }

    func testUnprotectedFavoritesGetTheConservativeTier() {
        let decision = decide(makeAsset(favorite: true), settings: PolicySettings(protectFavorites: false))
        XCTAssertEqual(decision.outcome, .optimizeConservatively)
        XCTAssertEqual(decision.tier, .conservative)
        XCTAssertEqual(decision.risk, .low)
    }

    func testSupportedPhotosAndScreenshotsCanBeChosen() {
        for kind in [MediaKind.photo, .screenshot] {
            let decision = decide(makeImageAsset(kind: kind))
            XCTAssertEqual(decision.outcome, .optimizeConservatively)
            XCTAssertTrue(decision.requiresApproval)
        }
    }

    func testNoModeIsChosenAutomatically() {
        for asset in [makeAsset(), makeImageAsset()] {
            let decision = decide(asset, mode: .undecided)
            XCTAssertEqual(decision.outcome, .askUser)
            XCTAssertEqual(decision.reasons, [.modeRequired])
            XCTAssertFalse(decision.isCandidate)
        }
    }

    func testExplicitProtectionOverridesSpaceSavingAndTechnicalFacts() {
        var asset = makeImageAsset()
        asset.isHDR = true
        XCTAssertEqual(decide(asset, mode: .protected).outcome, .protect)
        XCTAssertEqual(decide(makeAsset(), protectedIds: ["a1"], mode: .spaceFirst).outcome, .protect)
    }

    func testSpaceFirstIsAnExplicitChoiceEvenForFavorites() {
        let decision = decide(makeAsset(favorite: true), mode: .spaceFirst)
        XCTAssertEqual(decision.outcome, .optimize)
        XCTAssertEqual(decision.tier, .spaceSaving)
        XCTAssertTrue(decision.reasons.contains(.spaceFirstSelected))
    }

    func testLivePhotosAndSpecialPhotosAreUnchanged() {
        var live = makeImageAsset()
        live.kind = .livePhoto
        XCTAssertEqual(decide(live).reasons, [.livePhotosDeferred])
        var depth = makeImageAsset()
        depth.isSpecialPhoto = true
        XCTAssertEqual(decide(depth).reasons, [.specialPhoto])
        XCTAssertEqual(decide(makeImageAsset(codec: "com.adobe.raw-image")).reasons, [.unsupportedCodec])
    }

    func testPhotoAndVideoSizeGatesAreIndependent() {
        XCTAssertTrue(decide(makeImageAsset(size: 1_000_000)).isCandidate)
        XCTAssertEqual(decide(makeAsset(size: 1_000_000)).reasons, [.tooSmall])
        XCTAssertEqual(decide(makeImageAsset(size: 100_000)).reasons, [.tooSmall])
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

    func testInvalidTimingIsNotCalledEfficient() {
        XCTAssertEqual(decide(makeAsset(fps: 0)).reasons, [.invalidMedia])
        XCTAssertEqual(decide(makeAsset(duration: .infinity)).reasons, [.invalidMedia])
    }
}

final class PlannerTests: XCTestCase {
    private let planner = CompressionPlanner()

    func testPlanOffersAscendingRungsBelowTheSource() throws {
        let plan = try XCTUnwrap(planner.plan(for: makeAsset(), tier: .standard))
        XCTAssertEqual(plan.rungs.compactMap(\.videoSettings).map(\.bitrate), [3_110_400, 4_354_560, 5_598_720])
        XCTAssertEqual(plan.assetId, "a1")
    }

    func testRungsAboveTheSavingsCeilingAreDropped() throws {
        let plan = try XCTUnwrap(planner.plan(for: makeAsset(bitrate: 5_000_000), tier: .standard))
        XCTAssertEqual(plan.rungs.compactMap(\.videoSettings).map(\.bitrate), [3_110_400])
    }

    func testNoPlanWhenTheSourceIsAlreadyLow() {
        XCTAssertNil(planner.plan(for: makeAsset(bitrate: 3_000_000), tier: .standard))
    }

    func testNoPlanWithoutAnalysis() {
        XCTAssertNil(planner.plan(for: makeAsset(bitrate: nil, fps: nil, codec: nil), tier: .standard))
    }

    func testConservativeTierStartsHigher() throws {
        let plan = try XCTUnwrap(planner.plan(for: makeAsset(), tier: .conservative))
        XCTAssertEqual(plan.rungs.first?.videoSettings?.bitrate, 4_976_640)
    }

    func testSpaceFirstFits720pWithoutChangingFrameRate() throws {
        for (width, height, expectedWidth, expectedHeight) in [(3840, 2160, 1280, 720), (2160, 3840, 720, 1280)] {
            let asset = makeAsset(width: width, height: height, bitrate: 80_000_000, fps: 60)
            let plan = try XCTUnwrap(planner.plan(for: asset, tier: .spaceSaving))
            let settings = try XCTUnwrap(plan.rungs.first?.videoSettings)
            XCTAssertEqual(settings.width, expectedWidth)
            XCTAssertEqual(settings.height, expectedHeight)
            XCTAssertEqual(settings.frameRate, 60)
        }
    }

    func testAlmostIdenticalNeverReducesDimensions() throws {
        let asset = makeAsset(width: 3840, height: 2160, bitrate: 80_000_000)
        let plan = try XCTUnwrap(planner.plan(for: asset, tier: .conservative))
        XCTAssertTrue(plan.rungs.allSatisfy { $0.width == 3840 && $0.height == 2160 })
    }

    func testDetectedTextPreventsAutomaticVideoDownscaling() throws {
        let asset = makeAsset(
            width: 3840, height: 2160, bitrate: 80_000_000, hints: ContentHints(containsText: true)
        )
        let plan = try XCTUnwrap(planner.plan(for: asset, tier: .spaceSaving))
        XCTAssertEqual(plan.rungs.first?.width, 3840)
    }

    func testHighMotionGetsAGentlerBitrateBudget() throws {
        let high = makeAsset(hints: ContentHints(motion: .high))
        let low = makeAsset(hints: ContentHints(motion: .low))
        let highPlan = try XCTUnwrap(planner.plan(for: high, tier: .conservative))
        let lowPlan = try XCTUnwrap(planner.plan(for: low, tier: .conservative))
        let highBitrate = try XCTUnwrap(highPlan.rungs.first?.videoSettings?.bitrate)
        let lowBitrate = try XCTUnwrap(lowPlan.rungs.first?.videoSettings?.bitrate)
        XCTAssertGreaterThan(highBitrate, lowBitrate)
    }

    func testScreenshotsTryLosslessFirstAndPreserveDimensions() throws {
        let asset = makeImageAsset(kind: .screenshot, codec: "public.png")
        let plan = try XCTUnwrap(planner.plan(for: asset, tier: .spaceSaving))
        guard case .image(let first) = try XCTUnwrap(plan.rungs.first) else { return XCTFail("expected an image plan") }
        XCTAssertEqual(first.format, .png)
        XCTAssertTrue(plan.rungs.allSatisfy { $0.width == 1600 && $0.height == 1200 })
    }

    func testTransparencyNeverGetsFlattenedIntoALossyFormat() throws {
        let asset = makeImageAsset(codec: "public.png", hints: ContentHints(hasTransparency: true))
        let plan = try XCTUnwrap(planner.plan(for: asset, tier: .spaceSaving))
        XCTAssertEqual(plan.rungs.count, 1)
        XCTAssertEqual(plan.rungs.first?.fileExtension, "png")
    }

    func testProtectedAndUndecidedModesCannotProducePlans() {
        XCTAssertNil(planner.plan(for: makeAsset(), tier: .standard, mode: .protected))
        XCTAssertNil(planner.plan(for: makeImageAsset(), tier: .standard, mode: .undecided))
    }

    func testSpaceFirstCanFallBackToFullResolutionWhenSmallerFramesFail() throws {
        let asset = makeAsset(width: 3840, height: 2160, bitrate: 80_000_000)
        let plan = try XCTUnwrap(planner.plan(for: asset, tier: .spaceSaving))
        XCTAssertTrue(plan.rungs.contains { $0.width == 1280 && $0.height == 720 })
        XCTAssertTrue(plan.rungs.contains { $0.width == 3840 && $0.height == 2160 })
    }
}
