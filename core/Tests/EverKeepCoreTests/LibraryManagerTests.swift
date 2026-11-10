import XCTest
@testable import EverKeepCore

final class LibraryManagerTests: XCTestCase {
    private func unanalyzed(_ id: String, size: Int64, favorite: Bool = false) -> MediaAsset {
        makeAsset(id, size: size, bitrate: nil, fps: nil, codec: nil, favorite: favorite)
    }

    func testSyncAnalyzesDecidesAndSummarizes() async throws {
        let library = FakeLibrary(assets: [unanalyzed("big", size: 200_000_000), unanalyzed("small", size: 1_000_000)])
        await library.setAnalysis(makeAsset("big", size: 200_000_000))
        let manager = MediaLibraryManager(library: library, catalogue: InMemoryCatalogueStore())

        let summary = try await manager.sync(settings: PolicySettings())

        XCTAssertEqual(summary.videoCount, 2)
        XCTAssertEqual(summary.candidateCount, 1)
        XCTAssertEqual(summary.candidateBytes, 200_000_000)
        XCTAssertEqual(summary.byOutcome[.optimize], 1)
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
        try await catalogue.setProtected("protected", true)
        let manager = MediaLibraryManager(library: library, catalogue: catalogue)

        _ = try await manager.sync(settings: PolicySettings())

        let analyzed = await library.analyzeCalls
        XCTAssertEqual(analyzed, ["normal"])
    }

    func testAnalysisIsReusedWhileTheAssetIsUnchanged() async throws {
        let library = FakeLibrary(assets: [unanalyzed("big", size: 200_000_000)])
        await library.setAnalysis(makeAsset("big", size: 200_000_000))
        let manager = MediaLibraryManager(library: library, catalogue: InMemoryCatalogueStore())

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
        let manager = MediaLibraryManager(library: library, catalogue: catalogue)
        _ = try await manager.sync(settings: PolicySettings())
        let before = try await catalogue.decision(for: "a1")
        XCTAssertEqual(before?.outcome, .optimize)

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
        let decision = PreservationPolicyEngine().decide(asset, protectedIds: [], settings: PolicySettings())

        func item(after states: [TransactionState]) throws -> LibraryItem {
            guard !states.isEmpty else { return LibraryItem(asset: asset, decision: decision, transaction: nil) }
            var tx = PreservationTransaction(id: "t", assetId: "a1", originalBytes: 1, plan: nil, at: Date())
            for state in states { try tx.move(to: state, at: Date()) }
            return LibraryItem(asset: asset, decision: decision, transaction: tx)
        }

        XCTAssertTrue(try item(after: []).isPrepareable)
        XCTAssertTrue(try item(after: [.preparing, .failed]).isPrepareable)
        XCTAssertFalse(try item(after: [.preparing, .validating, .ready]).isPrepareable)
        XCTAssertFalse(try item(after: [.preparing, .validating, .rejected]).isPrepareable)
    }
}
