import XCTest
@testable import EverKeepCore

final class QualityPolicyTests: XCTestCase {
    private let policy = QualityPolicy()

    private func verdict(_ finding: ValidationFinding, original: Int64 = 100_000_000, tier: QualityTier = .standard) -> QualityVerdict {
        policy.evaluate(finding: finding, originalBytes: original, tier: tier)
    }

    func testGoodFindingPasses() {
        XCTAssertEqual(verdict(goodFinding()), .pass)
    }

    func testMissingEvidenceFailsClosed() {
        XCTAssertEqual(verdict(ValidationFinding()), .fail([.integrityMissing, .qualityMissing, .previewMissing, .detailsMissing]))
        XCTAssertEqual(
            verdict(ValidationFinding(integrity: goodFinding().integrity)),
            .fail([.qualityMissing, .previewMissing, .detailsMissing])
        )
        XCTAssertEqual(
            verdict(ValidationFinding(quality: goodFinding().quality)),
            .fail([.integrityMissing, .previewMissing, .detailsMissing])
        )
    }

    func testLowSimilarityFails() {
        XCTAssertEqual(verdict(lowQualityFinding()), .fail([.meanSSIMTooLow, .minSSIMTooLow]))
    }

    func testConservativeTierIsStricter() {
        var finding = goodFinding()
        finding.quality = QualityMetrics(meanSSIM: 0.988, minSSIM: 0.98, framesCompared: 12)
        XCTAssertEqual(verdict(finding, tier: .standard), .pass)
        XCTAssertEqual(verdict(finding, tier: .conservative), .fail([.meanSSIMTooLow]))
    }

    func testTooFewFramesFails() {
        XCTAssertEqual(verdict(goodFinding(frames: 3)), .fail([.tooFewFrames, .previewTooFewFrames, .detailsMissing]))
    }

    func testCandidateMustBeMeaningfullySmaller() {
        XCTAssertEqual(verdict(goodFinding(candidateBytes: 100_000_000)), .fail([.notSmaller]))
        XCTAssertEqual(verdict(goodFinding(candidateBytes: 95_000_000)), .fail([.belowMinimumSavings]))
        XCTAssertEqual(verdict(goodFinding(), original: 0), .fail([.originalSizeUnknown]))
    }

    func testIntegrityProblemsFail() {
        var finding = goodFinding()
        finding.integrity?.playable = false
        finding.integrity?.fullyDecoded = false
        finding.integrity?.durationDelta = 2
        finding.integrity?.dimensionsMatch = false
        finding.integrity?.audioTracksMatch = false
        finding.integrity?.frameRateDelta = 5
        finding.integrity?.colorMatches = false
        finding.integrity?.isHDR = true
        XCTAssertEqual(
            verdict(finding),
            .fail([.notPlayable, .decodeFailed, .durationMismatch, .dimensionsMismatch, .audioMismatch, .frameRateMismatch, .colorMismatch, .becameHDR])
        )
    }

    func testMergingKeepsEvidenceFromEveryValidator() {
        let good = goodFinding()
        let merged = ValidationFinding(integrity: good.integrity).merged(with: ValidationFinding(
            quality: good.quality, preview: good.preview, details: good.details
        ))
        XCTAssertEqual(merged, goodFinding())
    }

    func testPhotosRequireOneCompleteComparisonNotEightVideoFrames() {
        let finding = goodFinding(candidateBytes: 2_000_000, frames: 1)
        XCTAssertEqual(policy.evaluate(finding: finding, originalBytes: 5_000_000, tier: .conservative, kind: .photo), .pass)
        XCTAssertEqual(verdict(finding), .fail([.tooFewFrames, .previewTooFewFrames, .detailsMissing]))
    }

    func testAFullSizePassCannotHideABadOrMissingThumbnail() {
        var finding = goodFinding()
        finding.preview = nil
        XCTAssertEqual(verdict(finding), .fail([.previewMissing]))
        finding.preview = QualityMetrics(meanSSIM: 0.98, minSSIM: 0.96, framesCompared: 12)
        XCTAssertEqual(verdict(finding), .fail([.previewNotSimilar]))
    }

    func testMissingDetailChecksFailClosed() {
        var finding = goodFinding()
        finding.details = nil
        XCTAssertEqual(verdict(finding), .fail([.detailsMissing]))
    }

    func testChangedTextOrDamagedTextRegionsAreRejected() {
        var finding = goodFinding()
        finding.details = DetailMetrics(framesChecked: 12, textMatches: false, textRegions: 1, minTextSSIM: 1)
        XCTAssertEqual(verdict(finding), .fail([.textChanged]))
        finding.details = DetailMetrics(framesChecked: 12, textRegions: 1, minTextSSIM: 0.99)
        XCTAssertEqual(verdict(finding), .fail([.textNotSimilar]))
        finding.details?.minTextSSIM = nil
        XCTAssertEqual(verdict(finding), .fail([.textNotSimilar]))
    }

    func testFaceRegionsHaveTheirOwnThresholdEvenWhenTheAveragePasses() {
        var finding = goodFinding()
        finding.details = DetailMetrics(framesChecked: 12, faceRegions: 1, minFaceSSIM: 0.975)
        XCTAssertEqual(verdict(finding), .fail([.faceNotSimilar]))
        XCTAssertEqual(verdict(finding, tier: .spaceSaving), .pass)
    }

    func testNaNAndEmptyCandidateSizesCannotPass() {
        var finding = goodFinding()
        finding.quality?.meanSSIM = .nan
        XCTAssertEqual(verdict(finding), .fail([.invalidMetrics]))
        XCTAssertEqual(verdict(goodFinding(candidateBytes: 0)), .fail([.invalidCandidateSize]))
    }
}

final class SSIMTests: XCTestCase {
    private func ramp(width: Int, height: Int) -> LumaFrame {
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width { pixels.append(UInt8((x * 4 + y * 2) % 256)) }
        }
        return LumaFrame(width: width, height: height, pixels: pixels)!
    }

    private func noisy(_ frame: LumaFrame) -> LumaFrame {
        var seed: UInt32 = 12345
        let pixels = frame.pixels.map { value -> UInt8 in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Int(seed >> 24) % 41 - 20
            return UInt8(clamping: Int(value) + noise)
        }
        return LumaFrame(width: frame.width, height: frame.height, pixels: pixels)!
    }

    func testIdenticalFramesScoreOne() throws {
        let frame = ramp(width: 64, height: 64)
        XCTAssertEqual(try XCTUnwrap(SSIM.compare(frame, frame)), 1.0, accuracy: 1e-9)
    }

    func testNoiseLowersTheScore() throws {
        let frame = ramp(width: 64, height: 64)
        let score = try XCTUnwrap(SSIM.compare(frame, noisy(frame)))
        XCTAssertLessThan(score, 0.9)
        XCTAssertGreaterThan(score, 0)
    }

    func testFramesOfDifferentSizeCannotBeCompared() {
        XCTAssertNil(SSIM.compare(ramp(width: 64, height: 64), ramp(width: 32, height: 32)))
    }

    func testFrameNeedsMatchingPixelCount() {
        XCTAssertNil(LumaFrame(width: 4, height: 4, pixels: [1, 2, 3]))
        XCTAssertNil(LumaFrame(width: 0, height: 4, pixels: []))
    }

    func testPartialEdgeBlocksAreNotIgnored() throws {
        let original = try XCTUnwrap(LumaFrame(width: 10, height: 10, pixels: Array(repeating: 0, count: 100)))
        var changed = original.pixels
        changed[99] = 255
        let candidate = try XCTUnwrap(LumaFrame(width: 10, height: 10, pixels: changed))
        XCTAssertLessThan(try XCTUnwrap(SSIM.compare(original, candidate)), 1)
    }
}
