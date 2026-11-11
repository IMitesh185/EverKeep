import Foundation

public struct LibraryItem: Identifiable, Equatable, Sendable {
    public let asset: MediaAsset
    public let decision: PreservationDecision?
    public let transaction: PreservationTransaction?
    public let mode: PreservationMode

    public var id: String { asset.id }

    public init(
        asset: MediaAsset,
        decision: PreservationDecision?,
        transaction: PreservationTransaction?,
        mode: PreservationMode = .undecided
    ) {
        self.asset = asset
        self.decision = decision
        self.transaction = transaction
        self.mode = mode
    }

    /// A candidate that has no transaction yet, or whose last attempt failed and may be retried.
    public var isPrepareable: Bool {
        guard mode.permitsOptimization, let decision, decision.isCandidate, decision.tier == mode.tier else { return false }
        guard let transaction else { return true }
        if transaction.state == .failed { return true }
        if transaction.state == .ready {
            return transaction.original?.matchesSnapshot(asset) != true
                || transaction.plan?.mode != mode || transaction.plan?.tier != mode.tier
                || transaction.plan?.qualityPolicyVersion != QualityPolicy.version
        }
        return transaction.state == .rejected
            && (transaction.plan?.mode != mode || transaction.plan?.tier != decision.tier
                || transaction.plan?.qualityPolicyVersion != QualityPolicy.version)
    }

    public var isReadyForReview: Bool {
        mode.permitsOptimization && decision?.isCandidate == true && transaction?.state == .ready
            && transaction?.original?.matchesSnapshot(asset) == true
            && decision?.tier == mode.tier && transaction?.plan?.tier == mode.tier
            && transaction?.plan?.mode == mode
            && transaction?.plan?.qualityPolicyVersion == QualityPolicy.version
    }
}

public struct LibrarySummary: Equatable, Sendable {
    public var videoCount = 0
    public var photoCount = 0
    public var analysisFailures = 0
    public var candidateCount = 0
    public var candidateBytes: Int64 = 0
    public var readyCount = 0
    public var committedCount = 0
    /// Measured from committed replacements only; never an estimate (F6).
    public var bytesSaved: Int64 = 0
    public var byOutcome: [Outcome: Int] = [:]

    public init() {}
}

/// Discovery and catalogue sync. Decisions are recomputed on every sync.
public struct MediaLibraryManager: Sendable {
    private let library: any LibraryPort
    private let catalogue: any CatalogueStore
    private let engine: PreservationPolicyEngine

    public init(
        library: any LibraryPort,
        catalogue: any CatalogueStore,
        engine: PreservationPolicyEngine = PreservationPolicyEngine()
    ) {
        self.library = library
        self.catalogue = catalogue
        self.engine = engine
    }

    public func sync(
        settings: PolicySettings,
        onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> LibrarySummary {
        let listed = try await library.enumerateAssets()
        let protectedIds = try await catalogue.protections()
        let modes = try await catalogue.preservationModes()
        let previous = try await catalogue.allAssets()
        let known = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })

        var merged: [MediaAsset] = []
        merged.reserveCapacity(listed.count)
        for (index, fresh) in listed.enumerated() {
            if Task.isCancelled { break }
            merged.append(try await resolve(
                fresh, known: known[fresh.id], protectedIds: protectedIds,
                mode: modes[fresh.id] ?? .undecided, settings: settings
            ))
            onProgress(index + 1, listed.count)
        }

        try await catalogue.upsert(assets: merged)
        try await catalogue.removeAssets(except: Set(listed.map(\.id)))
        for asset in merged {
            try await catalogue.save(decision: engine.decide(
                asset, protectedIds: protectedIds, settings: settings, mode: modes[asset.id] ?? .undecided
            ))
        }
        return try await summary()
    }

    public func setProtected(_ id: String, _ isProtected: Bool, settings: PolicySettings) async throws {
        try await setMode(id, isProtected ? .protected : .undecided, settings: settings)
    }

    public func setMode(_ id: String, _ mode: PreservationMode, settings: PolicySettings) async throws {
        try await catalogue.setPreservationMode(id, mode)
        guard let asset = try await catalogue.asset(id: id) else { return }
        let protectedIds = try await catalogue.protections()
        let resolved = try await resolve(asset, known: asset, protectedIds: protectedIds, mode: mode, settings: settings)
        try await catalogue.upsert(assets: [resolved])
        try await catalogue.save(decision: engine.decide(
            resolved, protectedIds: protectedIds, settings: settings, mode: mode
        ))
        try await catalogue.append(audit: AuditEntry(at: Date(), event: "preference.\(mode.rawValue)", assetId: id))
    }

    public func items() async throws -> [LibraryItem] {
        let assets = try await catalogue.allAssets()
        let modes = try await catalogue.preservationModes()
        let decisionList = try await catalogue.allDecisions()
        let decisions = Dictionary(uniqueKeysWithValues: decisionList.map { ($0.assetId, $0) })

        var latest: [String: PreservationTransaction] = [:]
        for tx in try await catalogue.allTransactions() {
            if let current = latest[tx.assetId], current.updatedAt >= tx.updatedAt { continue }
            latest[tx.assetId] = tx
        }

        return assets
            .map { LibraryItem(
                asset: $0, decision: decisions[$0.id], transaction: latest[$0.id], mode: modes[$0.id] ?? .undecided
            ) }
            .sorted { $0.asset.sizeBytes > $1.asset.sizeBytes }
    }

    public func summary() async throws -> LibrarySummary {
        var result = LibrarySummary()
        for item in try await items() {
            if item.asset.kind == .video { result.videoCount += 1 }
            if item.asset.kind.isImage { result.photoCount += 1 }
            if item.asset.analysisError != nil { result.analysisFailures += 1 }
            if let decision = item.decision { result.byOutcome[decision.outcome, default: 0] += 1 }
            if item.isPrepareable {
                result.candidateCount += 1
                result.candidateBytes += item.asset.sizeBytes
            }
            if item.isReadyForReview { result.readyCount += 1 }
        }
        for tx in try await catalogue.allTransactions() where tx.state == .committed {
            result.committedCount += 1
            result.bytesSaved += max(0, tx.originalBytes - (tx.candidateBytes ?? tx.originalBytes))
        }
        return result
    }

    private func resolve(
        _ fresh: MediaAsset,
        known: MediaAsset?,
        protectedIds: Set<String>,
        mode: PreservationMode,
        settings: PolicySettings
    ) async throws -> MediaAsset {
        guard needsAnalysis(fresh, protectedIds: protectedIds, mode: mode, settings: settings) else { return fresh }
        if let known, known.isAnalyzed, known.modificationDate == fresh.modificationDate,
           known.kind == fresh.kind,
           (known.sizeBytes == fresh.sizeBytes || (fresh.sizeBytes == 0 && fresh.modificationDate != nil)),
           known.duration == fresh.duration,
           known.pixelWidth == fresh.pixelWidth, known.pixelHeight == fresh.pixelHeight {
            var asset = fresh
            asset.codec = known.codec
            asset.bitrate = known.bitrate
            asset.frameRate = known.frameRate
            asset.isHDR = known.isHDR
            asset.audioTrackCount = known.audioTrackCount
            asset.isOnDevice = known.isOnDevice
            asset.sizeBytes = known.sizeBytes
            asset.contentHints = known.contentHints
            asset.isSpecialPhoto = known.isSpecialPhoto
            asset.analysisError = nil
            return asset
        }
        do {
            return try await library.analyze(fresh)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var failed = fresh
            failed.analysisError = String(describing: error)
            try await catalogue.append(audit: AuditEntry(
                at: Date(), event: "analysis.failed", assetId: fresh.id, detail: String(describing: error)
            ))
            return failed
        }
    }

    /// Probing media is slow, so skip items whose decision cannot depend on it.
    private func needsAnalysis(
        _ asset: MediaAsset,
        protectedIds: Set<String>,
        mode: PreservationMode,
        settings: PolicySettings
    ) -> Bool {
        guard mode.permitsOptimization, (asset.kind == .video || asset.kind.isImage),
              !asset.hasAdjustments, !asset.isSpecialVideo, asset.isSpecialPhoto != true, !asset.isHDR else { return false }
        if protectedIds.contains(asset.id) || (asset.isFavorite && settings.protectFavorites && !mode.permitsOptimization) { return false }
        if asset.kind.isImage, let codec = asset.codec, !EligibilityRules.supportedImageTypes.contains(codec) { return false }
        return asset.sizeBytes == 0 || asset.sizeBytes >= settings.minimumBytes(for: asset.kind)
    }
}
