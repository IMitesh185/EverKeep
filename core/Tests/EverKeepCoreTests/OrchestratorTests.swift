import XCTest
@testable import EverKeepCore

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [OrchestratorEvent] = []

    func append(_ event: OrchestratorEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var kinds: [OrchestratorEvent.Kind] {
        lock.lock()
        defer { lock.unlock() }
        return stored.map(\.kind)
    }
}

final class OrchestratorTests: XCTestCase {
    private func prepareOne(_ rig: Rig) async throws -> PreservationTransaction {
        let prepared = try await rig.orchestrator.prepare(assetIds: ["a1"])
        return try XCTUnwrap(prepared.first)
    }

    // MARK: Stage 1

    func testPreparesACandidateWithoutTouchingTheOriginal() async throws {
        let rig = try await Rig.make()
        let log = EventLog()
        let prepared = try await rig.orchestrator.prepare(assetIds: ["a1"]) { log.append($0) }
        let tx = try XCTUnwrap(prepared.first)

        XCTAssertEqual(tx.state, .ready)
        XCTAssertEqual(tx.rungIndex, 0)
        XCTAssertEqual(tx.candidateBytes, 40_000_000)
        XCTAssertEqual(log.kinds, [.encoding, .validating, .ready])
        let deleteCalls = await rig.library.deleteCalls
        let placed = await rig.destination.placed
        XCTAssertTrue(deleteCalls.isEmpty)
        XCTAssertTrue(placed.isEmpty)
    }

    func testLadderMovesToTheNextRungWhenQualityFails() async throws {
        let rig = try await Rig.make(findings: [lowQualityFinding(), goodFinding(candidateBytes: 50_000_000)])
        let tx = try await prepareOne(rig)

        XCTAssertEqual(tx.state, .ready)
        XCTAssertEqual(tx.rungIndex, 1)
        XCTAssertEqual(tx.candidateBytes, 50_000_000)
        let calls = await rig.codec.calls
        let removed = await rig.storage.removed
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(removed, ["\(tx.id)-0.mov"])
    }

    func testRejectsWhenNoRungClearsTheBar() async throws {
        let rig = try await Rig.make(findings: [lowQualityFinding()])
        let tx = try await prepareOne(rig)

        XCTAssertEqual(tx.state, .rejected)
        XCTAssertEqual(tx.note?.contains("meanSSIMTooLow"), true)
        let calls = await rig.codec.calls
        let deleteCalls = await rig.library.deleteCalls
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(deleteCalls.isEmpty)
    }

    func testEncoderFailureMarksTheItemFailedAndCleansUp() async throws {
        let codec = FakeCodec()
        await codec.setFailure(TestError.boom)
        let rig = try await Rig.make(codec: codec)
        let tx = try await prepareOne(rig)

        XCTAssertEqual(tx.state, .failed)
        XCTAssertEqual(tx.note, "boom")
        let removed = await rig.storage.removed
        XCTAssertEqual(removed, ["\(tx.id)-0.mov"])
    }

    func testLowFreeSpaceFailsBeforeEncoding() async throws {
        let rig = try await Rig.make()
        await rig.storage.setAvailable(1_000)
        let tx = try await prepareOne(rig)

        XCTAssertEqual(tx.state, .failed)
        XCTAssertEqual(tx.note, "not enough free space")
        let calls = await rig.codec.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testItemsWithoutACandidateDecisionAreSkipped() async throws {
        let rig = try await Rig.make()
        try await rig.catalogue.setProtected("a1", true)
        let asset = try await rig.catalogue.asset(id: "a1")
        try await rig.catalogue.save(decision: PreservationPolicyEngine().decide(
            try XCTUnwrap(asset), protectedIds: ["a1"], settings: PolicySettings()
        ))
        let prepared = try await rig.orchestrator.prepare(assetIds: ["a1", "missing"])
        XCTAssertTrue(prepared.isEmpty)
    }

    // MARK: Stage 2

    func testReplacesOnlyAfterApprovalAndAsksOnceForTheBatch() async throws {
        let rig = try await Rig.make()
        let tx = try await prepareOne(rig)
        let summary = try await rig.orchestrator.approve(transactionIds: [tx.id])

        XCTAssertEqual(summary.committed, 1)
        XCTAssertEqual(summary.bytesSaved, 60_000_000)
        let deleteCalls = await rig.library.deleteCalls
        let removed = await rig.storage.removed
        XCTAssertEqual(deleteCalls, [["a1"]])
        XCTAssertTrue(removed.contains("\(tx.id)-0.mov"))

        let stored = try await rig.catalogue.transaction(id: tx.id)
        XCTAssertEqual(stored?.state, .committed)
        XCTAssertEqual(stored?.replacementId, "new-a1")
        XCTAssertNil(stored?.stagingFile)
    }

    func testDeclinedDeletionKeepsBothCopies() async throws {
        let rig = try await Rig.make()
        await rig.library.setDeletion(.decline)
        let tx = try await prepareOne(rig)
        let summary = try await rig.orchestrator.approve(transactionIds: [tx.id])

        XCTAssertEqual(summary.committed, 0)
        XCTAssertEqual(summary.duplicatesKept, 1)
        XCTAssertEqual(summary.bytesSaved, 0)
        let stored = try await rig.catalogue.transaction(id: tx.id)
        XCTAssertEqual(stored?.state, .duplicateKept)
    }

    func testDeletionErrorKeepsBothCopies() async throws {
        let rig = try await Rig.make()
        await rig.library.setDeletion(.fail)
        let tx = try await prepareOne(rig)
        let summary = try await rig.orchestrator.approve(transactionIds: [tx.id])

        XCTAssertEqual(summary.duplicatesKept, 1)
        let stored = try await rig.catalogue.transaction(id: tx.id)
        XCTAssertEqual(stored?.state, .duplicateKept)
        XCTAssertEqual(stored?.note?.contains("deletion failed"), true)
    }

    func testUnfaithfulReplacementNeverReachesDeletion() async throws {
        let rig = try await Rig.make()
        await rig.library.setCheck(ReplacementCheck(exists: true, durationDelta: 3, dimensionsMatch: true, creationDateMatches: true))
        let tx = try await prepareOne(rig)
        let summary = try await rig.orchestrator.approve(transactionIds: [tx.id])

        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.committed, 0)
        let deleteCalls = await rig.library.deleteCalls
        XCTAssertTrue(deleteCalls.isEmpty)
        let stored = try await rig.catalogue.transaction(id: tx.id)
        XCTAssertEqual(stored?.state, .failed)
    }

    func testOnlyReadyTransactionsCanBeApproved() async throws {
        let rig = try await Rig.make(findings: [lowQualityFinding()])
        let rejected = try await prepareOne(rig)
        let summary = try await rig.orchestrator.approve(transactionIds: [rejected.id, "unknown"])

        XCTAssertEqual(summary, ApprovalSummary())
        let placed = await rig.destination.placed
        XCTAssertTrue(placed.isEmpty)
    }

    func testProtectionAfterPreparationBlocksReplacementEvenWithAStaleDecision() async throws {
        let rig = try await Rig.make()
        let tx = try await prepareOne(rig)
        try await rig.catalogue.setProtected("a1", true)
        let summary = try await rig.orchestrator.approve(transactionIds: [tx.id])
        let placed = await rig.destination.placed
        let deleted = await rig.library.deleteCalls
        XCTAssertEqual(summary.committed, 0)
        XCTAssertTrue(placed.isEmpty)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testProtectionWhilePlacingTheCopyBlocksDeletion() async throws {
        let rig = try await Rig.make()
        let catalogue = rig.catalogue
        await rig.destination.setOnPlace { try await catalogue.setProtected("a1", true) }
        let tx = try await prepareOne(rig)
        let summary = try await rig.orchestrator.approve(transactionIds: [tx.id])
        let deleted = await rig.library.deleteCalls
        XCTAssertEqual(summary.duplicatesKept, 1)
        XCTAssertEqual(summary.bytesSaved, 0)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testChangedOriginalCannotBeReplacedEvenAfterTheCatalogueIsRefreshed() async throws {
        let rig = try await Rig.make()
        let tx = try await prepareOne(rig)
        var changed = makeAsset()
        changed.modificationDate = Date(timeIntervalSince1970: 1_700_000_100)
        await rig.library.setListed([changed])
        try await rig.catalogue.upsert(assets: [changed])
        let summary = try await rig.orchestrator.approve(transactionIds: [tx.id])
        let placed = await rig.destination.placed
        XCTAssertEqual(summary.committed, 0)
        XCTAssertTrue(placed.isEmpty)
    }

    func testCandidateIsValidatedAgainBeforeImport() async throws {
        let rig = try await Rig.make(findings: [goodFinding(), lowQualityFinding()])
        let tx = try await prepareOne(rig)
        let summary = try await rig.orchestrator.approve(transactionIds: [tx.id])
        let placed = await rig.destination.placed
        XCTAssertEqual(summary.committed, 0)
        XCTAssertTrue(placed.isEmpty)
    }

    func testBadNativePhotosThumbnailKeepsTheOriginal() async throws {
        let rig = try await Rig.make()
        await rig.library.setCheck(ReplacementCheck(
            exists: true, durationDelta: 0, dimensionsMatch: true, creationDateMatches: true, previewMatches: false
        ))
        let tx = try await prepareOne(rig)
        let summary = try await rig.orchestrator.approve(transactionIds: [tx.id])
        let deleted = await rig.library.deleteCalls
        XCTAssertEqual(summary.committed, 0)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testPhotosUseAnImageFileAndTheSameApprovedReplacementWorkflow() async throws {
        let rig = try await Rig.make(
            asset: makeImageAsset(), findings: [goodFinding(candidateBytes: 2_000_000, frames: 1)],
            codec: FakeCodec(bytesPerRung: [2_000_000])
        )
        let prepared = try await rig.orchestrator.prepare(assetIds: ["p1"])
        let tx = try XCTUnwrap(prepared.first)
        XCTAssertEqual(tx.state, .ready)
        XCTAssertEqual(tx.stagingFile, "\(tx.id)-0.jpg")
        let summary = try await rig.orchestrator.approve(transactionIds: [tx.id])
        XCTAssertEqual(summary.committed, 1)
        XCTAssertEqual(summary.bytesSaved, 3_000_000)
    }

    func testModeChangeInvalidatesThePreparedCandidate() async throws {
        let rig = try await Rig.make()
        let tx = try await prepareOne(rig)
        try await rig.catalogue.setPreservationMode("a1", .spaceFirst)
        let summary = try await rig.orchestrator.approve(transactionIds: [tx.id])
        let deleted = await rig.library.deleteCalls
        XCTAssertEqual(summary.committed, 0)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testAStaleSpaceFirstDecisionCannotDownscaleAnAlmostIdenticalItem() async throws {
        let rig = try await Rig.make(mode: .spaceFirst)
        try await rig.catalogue.setPreservationMode("a1", .almostIdentical)
        let prepared = try await rig.orchestrator.prepare(assetIds: ["a1"])
        let encoded = await rig.codec.calls
        XCTAssertTrue(prepared.isEmpty)
        XCTAssertTrue(encoded.isEmpty)
    }

    // MARK: Recovery

    private func openTransaction(
        _ rig: Rig,
        through states: [TransactionState],
        staging: String? = nil,
        replacement: String? = nil
    ) async throws {
        let storedAsset = try await rig.catalogue.asset(id: "a1")
        let asset = try XCTUnwrap(storedAsset)
        var tx = PreservationTransaction(
            id: "t1", assetId: "a1", originalBytes: 100_000_000,
            plan: CompressionPlanner().plan(for: asset, tier: .conservative),
            at: Date(timeIntervalSince1970: 0), original: asset
        )
        for state in states { try tx.move(to: state, at: Date(timeIntervalSince1970: 1)) }
        tx.stagingFile = staging
        tx.replacementId = replacement
        tx.candidateBytes = 40_000_000
        if let replacement { await rig.library.addExisting(replacement) }
        try await rig.catalogue.save(transaction: tx)
    }

    private let throughDeleting: [TransactionState] = [.preparing, .validating, .ready, .replacing, .verifying, .deleting]

    func testRecoveryRollsBackAnInterruptedPreparation() async throws {
        let rig = try await Rig.make()
        try await openTransaction(rig, through: [.preparing], staging: "t1-0.mov")
        let recovered = try await rig.orchestrator.recover()

        XCTAssertEqual(recovered.map(\.state), [.failed])
        let removed = await rig.storage.removed
        let deleteCalls = await rig.library.deleteCalls
        XCTAssertEqual(removed, ["t1-0.mov"])
        XCTAssertTrue(deleteCalls.isEmpty)
    }

    func testRecoveryDropsAReadyCandidateWhoseFileIsGone() async throws {
        let rig = try await Rig.make()
        try await openTransaction(rig, through: [.preparing, .validating, .ready], staging: "t1-0.mov")
        let recovered = try await rig.orchestrator.recover()
        XCTAssertEqual(recovered.map(\.state), [.failed])
    }

    func testRecoveryKeepsAReadyCandidateWhoseFileExists() async throws {
        let rig = try await Rig.make()
        await rig.storage.setStaged(["t1-0.mov"])
        try await openTransaction(rig, through: [.preparing, .validating, .ready], staging: "t1-0.mov")
        let recovered = try await rig.orchestrator.recover()

        XCTAssertTrue(recovered.isEmpty)
        let stored = try await rig.catalogue.transaction(id: "t1")
        XCTAssertEqual(stored?.state, .ready)
    }

    func testRecoveryCommitsWhenTheOriginalIsAlreadyGone() async throws {
        let rig = try await Rig.make()
        await rig.library.setExisting([])
        try await openTransaction(rig, through: throughDeleting, replacement: "new-a1")
        let recovered = try await rig.orchestrator.recover()
        XCTAssertEqual(recovered.map(\.state), [.committed])
    }

    func testRecoveryKeepsBothCopiesWhenDeletionWasNotConfirmed() async throws {
        let rig = try await Rig.make()
        try await openTransaction(rig, through: throughDeleting, replacement: "new-a1")
        let recovered = try await rig.orchestrator.recover()

        XCTAssertEqual(recovered.map(\.state), [.duplicateKept])
        let deleteCalls = await rig.library.deleteCalls
        XCTAssertTrue(deleteCalls.isEmpty, "recovery never deletes an original")
    }

    func testRecoveryFindsAReplacementCreatedBeforeTheInterruption() async throws {
        let rig = try await Rig.make()
        await rig.destination.setFound("found-1")
        await rig.library.addExisting("found-1")
        try await openTransaction(rig, through: [.preparing, .validating, .ready, .replacing])
        let recovered = try await rig.orchestrator.recover()

        XCTAssertEqual(recovered.map(\.state), [.duplicateKept])
        XCTAssertEqual(recovered.first?.replacementId, "found-1")
    }

    func testRecoveryFailsWhenNoReplacementWasCreated() async throws {
        let rig = try await Rig.make()
        try await openTransaction(rig, through: [.preparing, .validating, .ready, .replacing])
        let recovered = try await rig.orchestrator.recover()
        XCTAssertEqual(recovered.map(\.state), [.failed])
    }

    func testRecoveryDoesNotClaimSavingsWhenBothCopiesAreGone() async throws {
        let rig = try await Rig.make()
        try await openTransaction(rig, through: throughDeleting, replacement: "new-a1")
        await rig.library.setExisting([])
        let recovered = try await rig.orchestrator.recover()
        XCTAssertFalse(recovered.contains { $0.state == .committed })
    }

    func testUnknownLibraryAccessDoesNotCountAsConfirmedDeletion() async throws {
        let rig = try await Rig.make()
        try await openTransaction(rig, through: throughDeleting, replacement: "new-a1")
        await rig.library.setExistenceFailure(TestError.boom)
        do {
            _ = try await rig.orchestrator.recover()
            XCTFail("recovery must report that existence could not be verified")
        } catch {
            XCTAssertEqual(error as? TestError, .boom)
        }
        let stored = try await rig.catalogue.transaction(id: "t1")
        XCTAssertEqual(stored?.state, .deleting)
    }

    func testLegacyReadyCandidatesAreDiscardedRatherThanApproved() async throws {
        let rig = try await Rig.make()
        var tx = PreservationTransaction(id: "legacy", assetId: "a1", originalBytes: 100, plan: nil, at: Date())
        for state in [TransactionState.preparing, .validating, .ready] { try tx.move(to: state, at: Date()) }
        tx.stagingFile = "legacy.mov"
        try await rig.catalogue.save(transaction: tx)
        await rig.storage.setStaged(["legacy.mov"])
        let recovered = try await rig.orchestrator.recover()
        XCTAssertEqual(recovered.map(\.state), [.rejected])
        let deleted = await rig.library.deleteCalls
        XCTAssertTrue(deleted.isEmpty)
    }
}
