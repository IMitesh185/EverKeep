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
            let mode = try await catalogue.preservationModes()[id] ?? .undecided
            guard try await permissionMatches(assetId: id, mode: mode, tier: decision.tier) else { continue }
            try await discardCandidates(assetId: id)
            results.append(try await prepareOne(asset: asset, tier: decision.tier, mode: mode, onEvent: onEvent))
        }
        return results
    }

    private func prepareOne(
        asset: MediaAsset,
        tier: QualityTier,
        mode: PreservationMode,
        onEvent: @escaping OrchestratorEventHandler
    ) async throws -> PreservationTransaction {
        guard let plan = planner.plan(for: asset, tier: tier, mode: mode) else {
            var skipped = PreservationTransaction(id: makeID(), assetId: asset.id, originalBytes: asset.sizeBytes, plan: nil, at: now())
            try await catalogue.save(transaction: skipped)
            try await advance(&skipped, to: .rejected, note: "no encoding saves enough")
            onEvent(OrchestratorEvent(assetId: asset.id, kind: .rejected, detail: skipped.note))
            return skipped
        }

        var tx = PreservationTransaction(
            id: makeID(), assetId: asset.id, originalBytes: asset.sizeBytes, plan: plan, at: now(), original: asset
        )
        try await catalogue.save(transaction: tx)
        var lastFailures: [QualityFailure] = []
        let assetId = asset.id
        let rungCount = plan.rungs.count

        for (index, rung) in plan.rungs.enumerated() {
            tx.rungIndex = index
            try await advance(&tx, to: .preparing)
            let name = "\(tx.id)-\(index).\(rung.fileExtension)"
            tx.stagingFile = name

            do {
                guard try await permissionMatches(assetId: asset.id, mode: mode, tier: tier) else {
                    tx.stagingFile = nil
                    try await advance(&tx, to: .rejected, note: "preservation preference changed; the original is untouched")
                    onEvent(OrchestratorEvent(assetId: assetId, kind: .rejected, detail: tx.note))
                    return tx
                }
                guard let current = try await library.currentAsset(id: asset.id), asset.matchesSnapshot(current) else {
                    tx.stagingFile = nil
                    try await advance(&tx, to: .failed, note: "the original changed; scan the library again")
                    onEvent(OrchestratorEvent(assetId: assetId, kind: .failed, detail: tx.note))
                    return tx
                }
                let estimate = rung.stagingBudget(for: asset)
                let available = try await storage.availableBytes()
                guard available >= estimate, available - estimate >= reserveBytes else {
                    tx.stagingFile = nil
                    try await advance(&tx, to: .failed, note: "not enough free space")
                    onEvent(OrchestratorEvent(assetId: assetId, kind: .failed, detail: tx.note))
                    return tx
                }

                try await catalogue.save(transaction: tx)
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
                let finding = try await validate(asset: asset, url: url, settings: rung)
                tx.finding = finding

                switch policy.evaluate(finding: finding, originalBytes: asset.sizeBytes, tier: tier, kind: asset.kind) {
                case .pass:
                    guard finding.integrity?.candidateBytes == result.bytes,
                          try await permissionMatches(assetId: asset.id, mode: mode, tier: tier) else {
                        await storage.removeStaged(name: name)
                        tx.stagingFile = nil
                        try await advance(&tx, to: .rejected, note: "candidate size or preservation preference changed")
                        onEvent(OrchestratorEvent(assetId: assetId, kind: .rejected, detail: tx.note))
                        return tx
                    }
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

    public func discardCandidates(assetId: String) async throws {
        for var tx in try await catalogue.transactions(in: [.ready]) where tx.assetId == assetId {
            if let name = tx.stagingFile { await storage.removeStaged(name: name) }
            tx.stagingFile = nil
            try await advance(&tx, to: .rejected, note: "the candidate was discarded; the original is untouched")
        }
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
                  let name = tx.stagingFile,
                  let plan = tx.plan, plan.rungs.indices.contains(tx.rungIndex)
            else { continue }
            let settings = plan.rungs[tx.rungIndex]

            do {
                guard try await canApprove(tx, asset: asset) else {
                    await storage.removeStaged(name: name)
                    tx.stagingFile = nil
                    try await advance(&tx, to: .rejected, note: "the preference, original or validation policy changed; prepare again")
                    summary.failed += 1
                    onEvent(OrchestratorEvent(assetId: asset.id, kind: .rejected, detail: tx.note))
                    continue
                }
                let url = try await storage.stagingURL(name: name)
                onEvent(OrchestratorEvent(assetId: asset.id, kind: .validating))
                let finding = try await validate(asset: asset, url: url, settings: settings)
                guard policy.evaluate(
                    finding: finding, originalBytes: tx.originalBytes, tier: plan.tier, kind: asset.kind
                ) == .pass, finding.integrity?.candidateBytes == tx.candidateBytes,
                      try await canApprove(tx, asset: asset) else {
                    await storage.removeStaged(name: name)
                    tx.stagingFile = nil
                    try await advance(&tx, to: .rejected, note: "the candidate no longer passes validation; the original is untouched")
                    summary.failed += 1
                    onEvent(OrchestratorEvent(assetId: asset.id, kind: .rejected, detail: tx.note))
                    continue
                }
                tx.finding = finding
                try await advance(&tx, to: .replacing)
                onEvent(OrchestratorEvent(assetId: asset.id, kind: .replacing))
                let replacementId = try await destination.place(candidate: url, replacing: asset)
                await storage.removeStaged(name: name)
                tx.stagingFile = nil
                tx.replacementId = replacementId

                try await advance(&tx, to: .verifying)
                onEvent(OrchestratorEvent(assetId: asset.id, kind: .verifying))
                let check = try await library.verifyReplacement(
                    original: asset, replacementId: replacementId, settings: settings
                )
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

        var deletable: [(tx: PreservationTransaction, asset: MediaAsset)] = []
        for item in pending {
            do {
                if try await canApprove(item.tx, asset: item.asset) {
                    deletable.append(item)
                    continue
                }
            } catch {
                try await catalogue.append(audit: AuditEntry(
                    at: now(), event: "deletion.blocked", assetId: item.asset.id, detail: String(describing: error)
                ))
            }
            var tx = item.tx
            try await advance(&tx, to: .duplicateKept, note: "the original could not be re-confirmed or its preference changed; no deletion was requested")
            summary.duplicatesKept += 1
            onEvent(OrchestratorEvent(assetId: item.asset.id, kind: .duplicateKept, detail: tx.note))
        }
        guard !deletable.isEmpty else { return summary }

        var deleted: Set<String> = []
        var deletionError: String?
        do {
            deleted = try await library.deleteOriginals(ids: deletable.map { $0.asset.id })
        } catch {
            deletionError = "deletion failed: \(error); both copies are kept"
        }

        for item in deletable {
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
                guard tx.original != nil, let asset = try await catalogue.asset(id: tx.assetId),
                      let plan = tx.plan, plan.qualityPolicyVersion == QualityPolicy.version,
                      let mode = plan.mode,
                      try await permissionMatches(assetId: asset.id, mode: mode, tier: plan.tier) else {
                    if let name = tx.stagingFile { await storage.removeStaged(name: name) }
                    tx.stagingFile = nil
                    try await advance(&tx, to: .rejected, note: "the preference or quality policy changed; prepare again")
                    break
                }
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
        let catalogued = try await catalogue.asset(id: tx.assetId)
        guard let asset = catalogued ?? tx.original else {
            try await walk(&tx, to: unresolved, note: "the original is no longer catalogued")
            return
        }
        let originalExists = try await library.assetExists(id: asset.id)
        let replacementWasRecorded = tx.replacementId != nil
        if tx.replacementId == nil, let plan = tx.plan, plan.rungs.indices.contains(tx.rungIndex) {
            tx.replacementId = try await destination.findReplacement(for: asset, settings: plan.rungs[tx.rungIndex])
        }
        var replacementExists = false
        if let replacementId = tx.replacementId {
            replacementExists = try await library.assetExists(id: replacementId)
        }

        if originalExists, replacementExists {
            try await walk(&tx, to: .duplicateKept, note: "interrupted before the deletion was confirmed; both copies are kept")
        } else if !originalExists, replacementExists, replacementWasRecorded {
            try await walk(&tx, to: .committed)
        } else {
            let note: String
            if originalExists {
                note = "interrupted before the replacement was confirmed"
            } else if replacementExists {
                note = "the original is gone but the replacement could not be proven; check Photos"
            } else {
                note = "the original is gone and no replacement was found; check Photos"
            }
            try await walk(&tx, to: unresolved, note: note)
        }
    }

    // MARK: State persistence

    private func permissionMatches(assetId: String, mode: PreservationMode, tier: QualityTier) async throws -> Bool {
        guard mode.permitsOptimization else { return false }
        let modes = try await catalogue.preservationModes()
        let protectedIds = try await catalogue.protections()
        guard modes[assetId] == mode, !protectedIds.contains(assetId),
              let decision = try await catalogue.decision(for: assetId) else { return false }
        return decision.isCandidate && decision.tier == tier && tier == mode.tier
            && decision.policyVersion == PreservationPolicyEngine.version
    }

    private func canApprove(_ tx: PreservationTransaction, asset: MediaAsset) async throws -> Bool {
        guard let plan = tx.plan, let mode = plan.mode, let original = tx.original,
              plan.qualityPolicyVersion == QualityPolicy.version,
              try await permissionMatches(assetId: asset.id, mode: mode, tier: plan.tier),
              let current = try await library.currentAsset(id: asset.id) else { return false }
        return original.matchesSnapshot(asset) && original.matchesSnapshot(current)
    }

    private func validate(asset: MediaAsset, url: URL, settings: EncodingSettings) async throws -> ValidationFinding {
        var finding = ValidationFinding()
        for validator in validators {
            finding = finding.merged(with: try await validator.validate(original: asset, candidate: url, settings: settings))
        }
        return finding
    }

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
