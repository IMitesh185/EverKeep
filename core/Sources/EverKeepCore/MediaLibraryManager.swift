import Foundation

public struct LibraryItem: Identifiable, Equatable, Sendable {
    public let asset: MediaAsset
    public let decision: PreservationDecision?
    public let transaction: PreservationTransaction?

    public var id: String { asset.id }

    public init(asset: MediaAsset, decision: PreservationDecision?, transaction: PreservationTransaction?) {
        self.asset = asset
        self.decision = decision
        self.transaction = transaction
    }

    /// A candidate that has no transaction yet, or whose last attempt failed and may be retried.
    public var isPrepareable: Bool {
        guard let decision, decision.isCandidate else { return false }
        guard let transaction else { return true }
        return transaction.state == .failed
    }
}

public struct LibrarySummary: Equatable, Sendable {
    public var videoCount = 0
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
        let previous = try await catalogue.allAssets()
        let known = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })

        var merged: [MediaAsset] = []
        merged.reserveCapacity(listed.count)
        for (index, fresh) in listed.enumerated() {
            if Task.isCancelled { break }
            merged.append(await resolve(fresh, known: known[fresh.id], protectedIds: protectedIds, settings: settings))
            onProgress(index + 1, listed.count)
        }

        try await catalogue.upsert(assets: merged)
        try await catalogue.removeAssets(except: Set(listed.map(\.id)))
        for asset in merged {
            try await catalogue.save(decision: engine.decide(asset, protectedIds: protectedIds, settings: settings))
        }
        return try await summary()
    }

    public func setProtected(_ id: String, _ isProtected: Bool, settings: PolicySettings) async throws {
        try await catalogue.setProtected(id, isProtected)
        guard let asset = try await catalogue.asset(id: id) else { return }
        let protectedIds = try await catalogue.protections()
        try await catalogue.save(decision: engine.decide(asset, protectedIds: protectedIds, settings: settings))
    }

    public func items() async throws -> [LibraryItem] {
        let assets = try await catalogue.allAssets()
        let decisionList = try await catalogue.allDecisions()
        let decisions = Dictionary(uniqueKeysWithValues: decisionList.map { ($0.assetId, $0) })

        var latest: [String: PreservationTransaction] = [:]
        for tx in try await catalogue.allTransactions() {
            if let current = latest[tx.assetId], current.updatedAt >= tx.updatedAt { continue }
            latest[tx.assetId] = tx
        }

        return assets
            .map { LibraryItem(asset: $0, decision: decisions[$0.id], transaction: latest[$0.id]) }
            .sorted { $0.asset.sizeBytes > $1.asset.sizeBytes }
    }

    public func summary() async throws -> LibrarySummary {
        var result = LibrarySummary()
        for item in try await items() {
            if item.asset.kind == .video { result.videoCount += 1 }
            if let decision = item.decision { result.byOutcome[decision.outcome, default: 0] += 1 }
            if item.isPrepareable {
                result.candidateCount += 1
                result.candidateBytes += item.asset.sizeBytes
            }
            if item.transaction?.state == .ready { result.readyCount += 1 }
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
        settings: PolicySettings
    ) async -> MediaAsset {
        if let known, known.isAnalyzed, known.sizeBytes == fresh.sizeBytes, known.duration == fresh.duration {
            var asset = fresh
            asset.codec = known.codec
            asset.bitrate = known.bitrate
            asset.frameRate = known.frameRate
            asset.isHDR = known.isHDR
            asset.audioTrackCount = known.audioTrackCount
            asset.isOnDevice = known.isOnDevice
            return asset
        }
        guard needsAnalysis(fresh, protectedIds: protectedIds, settings: settings) else { return fresh }
        return (try? await library.analyze(fresh)) ?? fresh
    }

    /// Probing media is slow, so skip items whose decision cannot depend on it.
    private func needsAnalysis(_ asset: MediaAsset, protectedIds: Set<String>, settings: PolicySettings) -> Bool {
        guard asset.kind == .video, !asset.hasAdjustments, !asset.isSpecialVideo else { return false }
        if protectedIds.contains(asset.id) || (asset.isFavorite && settings.protectFavorites) { return false }
        return asset.sizeBytes == 0 || asset.sizeBytes >= settings.minBytes
    }
}
