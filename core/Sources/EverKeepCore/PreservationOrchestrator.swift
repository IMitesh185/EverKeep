import Foundation

public typealias OrchestratorEventHandler = @Sendable (OrchestratorEvent) -> Void

public struct OrchestratorEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case encoding, validating, ready, rejected, failed
        case replacing, verifying, committed, duplicateKept
    }

    public let assetId: String
    public let kind: Kind
    public let fraction: Double?
    public let detail: String?

    public init(assetId: String, kind: Kind, fraction: Double? = nil, detail: String? = nil) {
        self.assetId = assetId
        self.kind = kind
        self.fraction = fraction
        self.detail = detail
    }
}

public struct ApprovalSummary: Equatable, Sendable {
    public var committed = 0
    public var duplicatesKept = 0
    public var failed = 0
    public var bytesSaved: Int64 = 0

    public init() {}
}

/// Drives one item at a time. State is persisted before every side effect so that a crash can be
/// recovered, and the original is touched only after a verified replacement and an approved deletion.
public actor PreservationOrchestrator {
    private let policy: QualityPolicy
    private let planner: CompressionPlanner
    private let library: any LibraryPort
    private let codec: any CodecPort
    private let validators: [any ValidationPort]
    private let storage: any StoragePort
    private let destination: any DestinationPort
    private let catalogue: any CatalogueStore
    private let reserveBytes: Int64
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String

    public init(
        policy: QualityPolicy = QualityPolicy(),
        planner: CompressionPlanner = CompressionPlanner(),
        library: any LibraryPort,
        codec: any CodecPort,
        validators: [any ValidationPort],
        storage: any StoragePort,
        destination: any DestinationPort,
        catalogue: any CatalogueStore,
        reserveBytes: Int64 = 500_000_000,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.policy = policy
        self.planner = planner
        self.library = library
        self.codec = codec
        self.validators = validators
        self.storage = storage
        self.destination = destination
        self.catalogue = catalogue
        self.reserveBytes = reserveBytes
        self.now = now
        self.makeID = makeID
    }

    // MARK: Stage 1: prepare candidates (ADR-0003)

    @discardableResult
    public func prepare(
        assetIds: [String],
        onEvent: @escaping OrchestratorEventHandler = { _ in }
    ) async throws -> [PreservationTransaction] {
        var results: [PreservationTransaction] = []
        for id in assetIds {
            if Task.isCancelled { break }
            guard let asset = try await catalogue.asset(id: id),
                  let decision = try await catalogue.decision(for: id),
                  decision.isCandidate
            else { continue }
            results.append(try await prepareOne(asset: asset, tier: decision.tier, onEvent: onEvent))
        }
        return results
    }

    private func prepareOne(
        asset: MediaAsset,
        tier: QualityTier,
        onEvent: @escaping OrchestratorEventHandler
    ) async throws -> PreservationTransaction {
        guard let plan = planner.plan(for: asset, tier: tier) else {
            var skipped = PreservationTransaction(id: makeID(), assetId: asset.id, originalBytes: asset.sizeBytes, plan: nil, at: now())
            try await catalogue.save(transaction: skipped)
            try await advance(&skipped, to: .rejected, note: "no encoding saves enough")
            onEvent(OrchestratorEvent(assetId: asset.id, kind: .rejected, detail: skipped.note))
            return skipped
        }

        var tx = PreservationTransaction(id: makeID(), assetId: asset.id, originalBytes: asset.sizeBytes, plan: plan, at: now())
        try await catalogue.save(transaction: tx)
        var lastFailures: [QualityFailure] = []
        let assetId = asset.id
        let rungCount = plan.rungs.count

        for (index, rung) in plan.rungs.enumerated() {
            tx.rungIndex = index
            try await advance(&tx, to: .preparing)
            let name = "\(tx.id)-\(index).mov"
            tx.stagingFile = name

            do {
                let estimate = Int64(Double(rung.bitrate) * asset.duration / 8 * 1.25)
                let available = try await storage.availableBytes()
                guard available - estimate >= reserveBytes else {
                    tx.stagingFile = nil
                    try await advance(&tx, to: .failed, note: "not enough free space")
                    onEvent(OrchestratorEvent(assetId: assetId, kind: .failed, detail: tx.note))
                    return tx
                }

                let url = try await storage.stagingURL(name: name)
                let result = try await codec.encode(assetId: assetId, settings: rung, to: url) { fraction in
                    onEvent(OrchestratorEvent(
                        assetId: assetId,
                        kind: .encoding,
                        fraction: fraction,
                        detail: "rung \(index + 1) of \(rungCount)"
                    ))
                }
                tx.candidateBytes = result.bytes

                try await advance(&tx, to: .validating)
                onEvent(OrchestratorEvent(assetId: assetId, kind: .validating))
                var finding = ValidationFinding()
                for validator in validators {
                    finding = finding.merged(with: try await validator.validate(original: asset, candidate: url, settings: rung))
                }
                tx.finding = finding

                switch policy.evaluate(finding: finding, originalBytes: asset.sizeBytes, tier: tier) {
                case .pass:
                    try await advance(&tx, to: .ready)
                    onEvent(OrchestratorEvent(assetId: assetId, kind: .ready))
                    return tx
                case .fail(let failures):
                    lastFailures = failures
                    await storage.removeStaged(name: name)
                    tx.stagingFile = nil
                }
            } catch is CancellationError {
                await storage.removeStaged(name: name)
                tx.stagingFile = nil
                try await advance(&tx, to: .failed, note: "cancelled")
                return tx
            } catch {
                await storage.removeStaged(name: name)
                tx.stagingFile = nil
                try await advance(&tx, to: .failed, note: String(describing: error))
                onEvent(OrchestratorEvent(assetId: assetId, kind: .failed, detail: tx.note))
                return tx
            }
        }

        let reasons = lastFailures.map(\.rawValue).joined(separator: ", ")
        try await advance(&tx, to: .rejected, note: "quality bar not met: \(reasons)")
        onEvent(OrchestratorEvent(assetId: assetId, kind: .rejected, detail: tx.note))
        return tx
    }

    // MARK: Stage 2: replace after approval

    /// Places and verifies each approved candidate, then asks for one deletion confirmation for the batch.
    public func approve(
        transactionIds: [String],
        onEvent: @escaping OrchestratorEventHandler = { _ in }
    ) async throws -> ApprovalSummary {
        var summary = ApprovalSummary()
        var pending: [(tx: PreservationTransaction, asset: MediaAsset)] = []

        for id in transactionIds {
            if Task.isCancelled { break }
            guard var tx = try await catalogue.transaction(id: id), tx.state == .ready,
                  let asset = try await catalogue.asset(id: tx.assetId),
                  let name = tx.stagingFile
            else { continue }

            do {
                let url = try await storage.stagingURL(name: name)
                try await advance(&tx, to: .replacing)
                onEvent(OrchestratorEvent(assetId: asset.id, kind: .replacing))
                let replacementId = try await destination.place(candidate: url, replacing: asset)
                await storage.removeStaged(name: name)
                tx.stagingFile = nil
                tx.replacementId = replacementId

                try await advance(&tx, to: .verifying)
                onEvent(OrchestratorEvent(assetId: asset.id, kind: .verifying))
                let check = try await library.verifyReplacement(original: asset, replacementId: replacementId)
                guard check.isFaithful else {
                    try await advance(&tx, to: .failed, note: "the replacement did not match the original; both copies are kept")
                    summary.failed += 1
                    onEvent(OrchestratorEvent(assetId: asset.id, kind: .failed, detail: tx.note))
                    continue
                }

                try await advance(&tx, to: .deleting)
                pending.append((tx: tx, asset: asset))
            } catch {
                await storage.removeStaged(name: name)
                tx.stagingFile = nil
                try await advance(&tx, to: .failed, note: String(describing: error))
                summary.failed += 1
                onEvent(OrchestratorEvent(assetId: asset.id, kind: .failed, detail: tx.note))
            }
        }

        guard !pending.isEmpty else { return summary }

        var deleted: Set<String> = []
        var deletionError: String?
        do {
            deleted = try await library.deleteOriginals(ids: pending.map { $0.asset.id })
        } catch {
            deletionError = "deletion failed: \(error); both copies are kept"
        }

        for item in pending {
            var tx = item.tx
            if deleted.contains(item.asset.id) {
                try await advance(&tx, to: .committed)
                summary.committed += 1
                summary.bytesSaved += max(0, item.asset.sizeBytes - (tx.candidateBytes ?? item.asset.sizeBytes))
                onEvent(OrchestratorEvent(assetId: item.asset.id, kind: .committed))
            } else {
                try await advance(&tx, to: .duplicateKept, note: deletionError ?? "deletion was declined; both copies are kept")
                summary.duplicatesKept += 1
                onEvent(OrchestratorEvent(assetId: item.asset.id, kind: .duplicateKept, detail: tx.note))
            }
        }
        return summary
    }

    // MARK: Recovery

    /// Resumes or rolls back whatever a crash or kill left open. It never deletes an original.
    @discardableResult
    public func recover() async throws -> [PreservationTransaction] {
        let open: Set<TransactionState> = [.proposed, .preparing, .validating, .ready, .replacing, .verifying, .deleting]
        var updated: [PreservationTransaction] = []

        for var tx in try await catalogue.transactions(in: open) {
            switch tx.state {
            case .proposed, .preparing, .validating:
                if let name = tx.stagingFile {
                    await storage.removeStaged(name: name)
                    tx.stagingFile = nil
                }
                try await advance(&tx, to: .failed, note: "interrupted before a candidate was ready")
            case .ready:
                if let name = tx.stagingFile, await storage.stagedFileExists(name: name) { continue }
                tx.stagingFile = nil
                try await advance(&tx, to: .failed, note: "the staged candidate is gone")
            case .replacing, .verifying, .deleting:
                try await recoverReplacement(&tx)
            default:
                continue
            }
            updated.append(tx)
        }
        return updated
    }

    private func recoverReplacement(_ tx: inout PreservationTransaction) async throws {
        // Past the point of no return a failure is not a legal state, so both copies are reported instead.
        let unresolved: TransactionState = tx.state == .deleting ? .duplicateKept : .failed
        guard let asset = try await catalogue.asset(id: tx.assetId) else {
            try await walk(&tx, to: unresolved, note: "the original is no longer catalogued")
            return
        }
        let originalExists = await library.assetExists(id: asset.id)
        if tx.replacementId == nil {
            tx.replacementId = try await destination.findReplacement(for: asset)
        }

        if originalExists, tx.replacementId != nil {
            try await walk(&tx, to: .duplicateKept, note: "interrupted before the deletion was confirmed; both copies are kept")
        } else if !originalExists, tx.replacementId != nil {
            try await walk(&tx, to: .committed)
        } else {
            let note = originalExists
                ? "interrupted before the replacement was confirmed"
                : "the original is gone and no replacement was found; check Photos"
            try await walk(&tx, to: unresolved, note: note)
        }
    }

    // MARK: State persistence

    private func advance(_ tx: inout PreservationTransaction, to state: TransactionState, note: String? = nil) async throws {
        try tx.move(to: state, at: now(), note: note)
        try await catalogue.save(transaction: tx)
        try await catalogue.append(audit: AuditEntry(
            at: now(),
            event: "transaction.\(state.rawValue)",
            assetId: tx.assetId,
            detail: note ?? ""
        ))
    }

    /// Moves through the intermediate states so that every step stays a legal transition.
    private func walk(_ tx: inout PreservationTransaction, to target: TransactionState, note: String? = nil) async throws {
        let order: [TransactionState] = [.replacing, .verifying, .deleting]
        if target == .committed || target == .duplicateKept, let start = order.firstIndex(of: tx.state) {
            for next in order.dropFirst(start + 1) { try await advance(&tx, to: next) }
        }
        try await advance(&tx, to: target, note: note)
    }
}
