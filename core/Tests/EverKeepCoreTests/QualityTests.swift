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
        XCTAssertEqual(verdict(ValidationFinding()), .fail([.integrityMissing, .qualityMissing]))
        XCTAssertEqual(verdict(ValidationFinding(integrity: goodFinding().integrity)), .fail([.qualityMissing]))
        XCTAssertEqual(verdict(ValidationFinding(quality: goodFinding().quality)), .fail([.integrityMissing]))
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
        var finding = goodFinding()
        finding.quality = QualityMetrics(meanSSIM: 0.999, minSSIM: 0.999, framesCompared: 3)
        XCTAssertEqual(verdict(finding), .fail([.tooFewFrames]))
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
        let merged = ValidationFinding(integrity: goodFinding().integrity).merged(with: ValidationFinding(quality: goodFinding().quality))
        XCTAssertEqual(merged, goodFinding())
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
}
