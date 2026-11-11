import XCTest
@testable import EverKeepCore

final class LibraryManagerTests: XCTestCase {
    private func unanalyzed(_ id: String, size: Int64, favorite: Bool = false) -> MediaAsset {
        makeAsset(id, size: size, bitrate: nil, fps: nil, codec: nil, favorite: favorite)
    }

    func testSyncAnalyzesDecidesAndSummarizes() async throws {
        let library = FakeLibrary(assets: [unanalyzed("big", size: 200_000_000), unanalyzed("small", size: 1_000_000)])
        await library.setAnalysis(makeAsset("big", size: 200_000_000))
        let catalogue = InMemoryCatalogueStore()
        try await catalogue.setPreservationMode("big", .almostIdentical)
        let manager = MediaLibraryManager(library: library, catalogue: catalogue)

        let summary = try await manager.sync(settings: PolicySettings())

        XCTAssertEqual(summary.videoCount, 2)
        XCTAssertEqual(summary.candidateCount, 1)
        XCTAssertEqual(summary.candidateBytes, 200_000_000)
        XCTAssertEqual(summary.byOutcome[.optimizeConservatively], 1)
        XCTAssertEqual(summary.byOutcome[.keepAsIs], 1)
        let analyzed = await library.analyzeCalls
        XCTAssertEqual(analyzed, ["big"], "small videos are not probed")
    }

    func testProtectedAndFavoriteItemsAreNotProbed() async throws {
        let library = FakeLibrary(assets: [
            unanalyzed("normal", size: 200_000_000),
            unanalyzed("favorite", size: 200_000_000, favorite: true),
            unanalyzed("protected", size: 200_000_000),
        ])
        let catalogue = InMemoryCatalogueStore()
        try await catalogue.setPreservationMode("normal", .almostIdentical)
        try await catalogue.setProtected("protected", true)
        let manager = MediaLibraryManager(library: library, catalogue: catalogue)

        _ = try await manager.sync(settings: PolicySettings())

        let analyzed = await library.analyzeCalls
        XCTAssertEqual(analyzed, ["normal"])
    }

    func testAnalysisIsReusedWhileTheAssetIsUnchanged() async throws {
        let library = FakeLibrary(assets: [unanalyzed("big", size: 200_000_000)])
        await library.setAnalysis(makeAsset("big", size: 200_000_000))
        let catalogue = InMemoryCatalogueStore()
        try await catalogue.setPreservationMode("big", .almostIdentical)
        let manager = MediaLibraryManager(library: library, catalogue: catalogue)

        _ = try await manager.sync(settings: PolicySettings())
        _ = try await manager.sync(settings: PolicySettings())

        let analyzed = await library.analyzeCalls
        XCTAssertEqual(analyzed, ["big"])
    }

    func testSyncDropsAssetsThatLeftTheLibrary() async throws {
        let library = FakeLibrary(assets: [makeAsset("a"), makeAsset("b")])
        let catalogue = InMemoryCatalogueStore()
        let manager = MediaLibraryManager(library: library, catalogue: catalogue)

        _ = try await manager.sync(settings: PolicySettings())
        await library.setListed([makeAsset("a")])
        _ = try await manager.sync(settings: PolicySettings())

        let remaining = try await catalogue.allAssets().map(\.id)
        XCTAssertEqual(remaining, ["a"])
    }

    func testProtectingAnItemChangesItsDecision() async throws {
        let library = FakeLibrary(assets: [makeAsset("a1")])
        let catalogue = InMemoryCatalogueStore()
        try await catalogue.setPreservationMode("a1", .almostIdentical)
        let manager = MediaLibraryManager(library: library, catalogue: catalogue)
        _ = try await manager.sync(settings: PolicySettings())
        let before = try await catalogue.decision(for: "a1")
        XCTAssertEqual(before?.outcome, .optimizeConservatively)

        try await manager.setProtected("a1", true, settings: PolicySettings())

        let after = try await catalogue.decision(for: "a1")
        XCTAssertEqual(after?.outcome, .protect)
    }

    func testSavingsAreMeasuredFromCommittedTransactionsOnly() async throws {
        let catalogue = InMemoryCatalogueStore()
        let manager = MediaLibraryManager(library: FakeLibrary(), catalogue: catalogue)

        var committed = PreservationTransaction(id: "t1", assetId: "gone", originalBytes: 100_000_000, plan: nil, at: Date(timeIntervalSince1970: 0))
        let path: [TransactionState] = [.preparing, .validating, .ready, .replacing, .verifying, .deleting, .committed]
        for state in path { try committed.move(to: state, at: Date(timeIntervalSince1970: 1)) }
        committed.candidateBytes = 40_000_000
        try await catalogue.save(transaction: committed)

        var ready = PreservationTransaction(id: "t2", assetId: "other", originalBytes: 100_000_000, plan: nil, at: Date(timeIntervalSince1970: 0))
        for state in [TransactionState.preparing, .validating, .ready] { try ready.move(to: state, at: Date(timeIntervalSince1970: 1)) }
        ready.candidateBytes = 10_000_000
        try await catalogue.save(transaction: ready)

        let summary = try await manager.summary()
        XCTAssertEqual(summary.committedCount, 1)
        XCTAssertEqual(summary.bytesSaved, 60_000_000)
    }

    func testOnlyUntouchedOrFailedCandidatesCanBePrepared() async throws {
        let asset = makeAsset("a1")
        let decision = PreservationPolicyEngine().decide(
            asset, protectedIds: [], settings: PolicySettings(), mode: .almostIdentical
        )
        let plan = CompressionPlanner().plan(for: asset, tier: .conservative)

        func item(after states: [TransactionState]) throws -> LibraryItem {
            guard !states.isEmpty else {
                return LibraryItem(asset: asset, decision: decision, transaction: nil, mode: .almostIdentical)
            }
            var tx = PreservationTransaction(id: "t", assetId: "a1", originalBytes: 1, plan: plan, at: Date(), original: asset)
            for state in states { try tx.move(to: state, at: Date()) }
            return LibraryItem(asset: asset, decision: decision, transaction: tx, mode: .almostIdentical)
        }

        XCTAssertTrue(try item(after: []).isPrepareable)
        XCTAssertTrue(try item(after: [.preparing, .failed]).isPrepareable)
        XCTAssertFalse(try item(after: [.preparing, .validating, .ready]).isPrepareable)
        XCTAssertFalse(try item(after: [.preparing, .validating, .rejected]).isPrepareable)
    }

    func testUnassignedItemsAreListedButNeverProbedOrPrepared() async throws {
        let library = FakeLibrary(assets: [makeAsset(), makeImageAsset()])
        let manager = MediaLibraryManager(library: library, catalogue: InMemoryCatalogueStore())
        let summary = try await manager.sync(settings: PolicySettings())
        let analyzed = await library.analyzeCalls
        XCTAssertTrue(analyzed.isEmpty)
        XCTAssertEqual(summary.photoCount, 1)
        XCTAssertEqual(summary.videoCount, 1)
        XCTAssertEqual(summary.byOutcome[.askUser], 2)
        XCTAssertEqual(summary.candidateCount, 0)
    }

    func testChoosingAModeAnalyzesAnUnassignedPhoto() async throws {
        var photo = makeImageAsset()
        photo.contentHints = nil
        let library = FakeLibrary(assets: [photo])
        await library.setAnalysis(makeImageAsset())
        let catalogue = InMemoryCatalogueStore()
        let manager = MediaLibraryManager(library: library, catalogue: catalogue)
        _ = try await manager.sync(settings: PolicySettings())
        try await manager.setMode("p1", .almostIdentical, settings: PolicySettings())
        let items = try await manager.items()
        XCTAssertEqual(items.first?.mode, .almostIdentical)
        XCTAssertEqual(items.first?.isPrepareable, true)
        let analyzed = await library.analyzeCalls
        XCTAssertEqual(analyzed, ["p1"])
    }

    func testAnalysisFailuresAreVisibleAndCannotCreateCandidates() async throws {
        let library = FakeLibrary(assets: [unanalyzed("a1", size: 100_000_000)])
        await library.setAnalysisFailure(TestError.boom)
        let catalogue = InMemoryCatalogueStore()
        try await catalogue.setPreservationMode("a1", .almostIdentical)
        let manager = MediaLibraryManager(library: library, catalogue: catalogue)
        let summary = try await manager.sync(settings: PolicySettings())
        XCTAssertEqual(summary.analysisFailures, 1)
        XCTAssertEqual(summary.candidateCount, 0)
        let audit = try await catalogue.recentAudit(limit: 10)
        XCTAssertEqual(audit.first?.event, "analysis.failed")
        let decision = try await catalogue.decision(for: "a1")
        XCTAssertEqual(decision?.reasons, [.analysisFailed])
    }

    func testModificationDateInvalidatesCachedAnalysis() async throws {
        let library = FakeLibrary(assets: [makeAsset()])
        let catalogue = InMemoryCatalogueStore()
        try await catalogue.setPreservationMode("a1", .almostIdentical)
        let manager = MediaLibraryManager(library: library, catalogue: catalogue)
        _ = try await manager.sync(settings: PolicySettings())
        var changed = makeAsset()
        changed.modificationDate = Date(timeIntervalSince1970: 1_700_000_100)
        await library.setListed([changed])
        _ = try await manager.sync(settings: PolicySettings())
        let analyzed = await library.analyzeCalls
        XCTAssertEqual(analyzed.count, 2)
    }

    func testModeChangesUpdateLegacyProtectionAtomically() async throws {
        let catalogue = InMemoryCatalogueStore()
        try await catalogue.setProtected("a1", true)
        var modes = try await catalogue.preservationModes()
        XCTAssertEqual(modes["a1"], .protected)
        try await catalogue.setPreservationMode("a1", .spaceFirst)
        modes = try await catalogue.preservationModes()
        let protected = try await catalogue.protections()
        XCTAssertEqual(modes["a1"], .spaceFirst)
        XCTAssertFalse(protected.contains("a1"))
    }

    func testChangedOriginalCanBePreparedAgainInsteadOfReviewingAStaleCopy() throws {
        let source = makeAsset()
        var current = source
        current.modificationDate = Date(timeIntervalSince1970: 1_700_000_100)
        let decision = PreservationPolicyEngine().decide(
            current, protectedIds: [], settings: PolicySettings(), mode: .almostIdentical
        )
        var tx = PreservationTransaction(
            id: "stale", assetId: source.id, originalBytes: source.sizeBytes,
            plan: CompressionPlanner().plan(for: source, tier: .conservative), at: Date(), original: source
        )
        for state in [TransactionState.preparing, .validating, .ready] { try tx.move(to: state, at: Date()) }
        let item = LibraryItem(asset: current, decision: decision, transaction: tx, mode: .almostIdentical)
        XCTAssertFalse(item.isReadyForReview)
        XCTAssertTrue(item.isPrepareable)
    }
}
