import Foundation

public actor InMemoryCatalogueStore: CatalogueStore {
    private var assets: [String: MediaAsset] = [:]
    private var decisions: [String: PreservationDecision] = [:]
    private var storedTransactions: [String: PreservationTransaction] = [:]
    private var protected: Set<String> = []
    private var modes: [String: PreservationMode] = [:]
    private var audit: [AuditEntry] = []

    public init() {}

    public func upsert(assets newAssets: [MediaAsset]) async throws {
        for asset in newAssets { assets[asset.id] = asset }
    }

    public func removeAssets(except ids: Set<String>) async throws {
        assets = assets.filter { ids.contains($0.key) }
        decisions = decisions.filter { ids.contains($0.key) }
    }

    public func asset(id: String) async throws -> MediaAsset? { assets[id] }

    public func allAssets() async throws -> [MediaAsset] { Array(assets.values) }

    public func save(decision: PreservationDecision) async throws {
        decisions[decision.assetId] = decision
    }

    public func decision(for assetId: String) async throws -> PreservationDecision? { decisions[assetId] }

    public func allDecisions() async throws -> [PreservationDecision] { Array(decisions.values) }

    public func save(transaction: PreservationTransaction) async throws {
        storedTransactions[transaction.id] = transaction
    }

    public func transaction(id: String) async throws -> PreservationTransaction? { storedTransactions[id] }

    public func transactions(in states: Set<TransactionState>) async throws -> [PreservationTransaction] {
        storedTransactions.values.filter { states.contains($0.state) }.sorted { $0.createdAt < $1.createdAt }
    }

    public func allTransactions() async throws -> [PreservationTransaction] { Array(storedTransactions.values) }

    public func protections() async throws -> Set<String> { protected }

    public func setProtected(_ id: String, _ isProtected: Bool) async throws {
        try await setPreservationMode(id, isProtected ? .protected : .undecided)
    }

    public func preservationModes() async throws -> [String: PreservationMode] {
        var result = modes
        for id in protected { result[id] = .protected }
        return result
    }

    public func setPreservationMode(_ id: String, _ mode: PreservationMode) async throws {
        modes[id] = mode
        if mode == .protected { protected.insert(id) } else { protected.remove(id) }
    }

    public func append(audit entry: AuditEntry) async throws {
        var stored = entry
        stored.id = Int64(audit.count + 1)
        audit.append(stored)
    }

    public func recentAudit(limit: Int) async throws -> [AuditEntry] {
        Array(audit.suffix(max(0, limit)).reversed())
    }
}
