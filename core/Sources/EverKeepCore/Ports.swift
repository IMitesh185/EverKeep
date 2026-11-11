import Foundation

public enum LibraryAuthorization: String, Codable, Sendable {
    case notDetermined, denied, restricted, limited, authorized

    public var canRead: Bool { self == .authorized || self == .limited }
}

public struct ReplacementCheck: Equatable, Sendable {
    public var exists: Bool
    public var durationDelta: Double
    public var dimensionsMatch: Bool
    public var creationDateMatches: Bool
    public var previewMatches: Bool?

    public init(
        exists: Bool,
        durationDelta: Double,
        dimensionsMatch: Bool,
        creationDateMatches: Bool,
        previewMatches: Bool? = nil
    ) {
        self.exists = exists
        self.durationDelta = durationDelta
        self.dimensionsMatch = dimensionsMatch
        self.creationDateMatches = creationDateMatches
        self.previewMatches = previewMatches
    }

    public var isFaithful: Bool {
        exists && durationDelta.isFinite && durationDelta <= 0.1 && durationDelta >= 0
            && dimensionsMatch && creationDateMatches && previewMatches == true
    }
}

public struct EncodeResult: Equatable, Sendable {
    public let bytes: Int64

    public init(bytes: Int64) {
        self.bytes = bytes
    }
}

/// The photo library: authorization, enumeration, analysis, verification and deletion requests.
public protocol LibraryPort: Sendable {
    func authorizationState() async -> LibraryAuthorization
    func requestAuthorization() async -> LibraryAuthorization
    /// Fast: reads library properties only, no media probing.
    func enumerateAssets() async throws -> [MediaAsset]
    /// Probes the media for codec, bitrate, frame rate and HDR, and whether the original is on the device.
    func analyze(_ asset: MediaAsset) async throws -> MediaAsset
    func currentAsset(id: String) async throws -> MediaAsset?
    func assetExists(id: String) async throws -> Bool
    func verifyReplacement(original: MediaAsset, replacementId: String, settings: EncodingSettings) async throws -> ReplacementCheck
    /// One system confirmation for the whole batch. Returns the ids that are gone afterwards;
    /// a declined prompt returns an empty set rather than throwing.
    func deleteOriginals(ids: [String]) async throws -> Set<String>
}

public protocol CodecPort: Sendable {
    func encode(
        assetId: String,
        settings: EncodingSettings,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> EncodeResult
}

public protocol ValidationPort: Sendable {
    func validate(original: MediaAsset, candidate: URL, settings: EncodingSettings) async throws -> ValidationFinding
}

public protocol StoragePort: Sendable {
    func availableBytes() async throws -> Int64
    func stagingURL(name: String) async throws -> URL
    func stagedFileExists(name: String) async -> Bool
    func removeStaged(name: String) async
}

public protocol DestinationPort: Sendable {
    /// Creates the replacement in the destination (Photos in v1) and returns its identifier.
    func place(candidate: URL, replacing original: MediaAsset) async throws -> String
    /// Looks for a replacement created before an interruption, so a crash does not leave an unknown duplicate.
    func findReplacement(for original: MediaAsset, settings: EncodingSettings) async throws -> String?
}

public protocol CatalogueStore: Sendable {
    func upsert(assets: [MediaAsset]) async throws
    func removeAssets(except ids: Set<String>) async throws
    func asset(id: String) async throws -> MediaAsset?
    func allAssets() async throws -> [MediaAsset]

    func save(decision: PreservationDecision) async throws
    func decision(for assetId: String) async throws -> PreservationDecision?
    func allDecisions() async throws -> [PreservationDecision]

    func save(transaction: PreservationTransaction) async throws
    func transaction(id: String) async throws -> PreservationTransaction?
    func transactions(in states: Set<TransactionState>) async throws -> [PreservationTransaction]
    func allTransactions() async throws -> [PreservationTransaction]

    func protections() async throws -> Set<String>
    func setProtected(_ id: String, _ isProtected: Bool) async throws
    func preservationModes() async throws -> [String: PreservationMode]
    func setPreservationMode(_ id: String, _ mode: PreservationMode) async throws

    func append(audit: AuditEntry) async throws
    func recentAudit(limit: Int) async throws -> [AuditEntry]
}
