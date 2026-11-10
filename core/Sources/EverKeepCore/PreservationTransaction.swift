import Foundation

/// Persisted per-item lifecycle. The earlier lifecycle states (discovered, analyzed, decided, closed)
/// are the asset and decision records in the catalogue; a transaction starts when the user opts in.
public enum TransactionState: String, Codable, Sendable, CaseIterable {
    case proposed, preparing, validating, ready, rejected
    case replacing, verifying, deleting, committed, duplicateKept, failed

    public var isTerminal: Bool {
        switch self {
        case .rejected, .committed, .duplicateKept: return true
        default: return false
        }
    }

    public func canMove(to next: TransactionState) -> Bool {
        switch (self, next) {
        case (.proposed, .preparing), (.proposed, .rejected), (.proposed, .failed),
             (.preparing, .validating), (.preparing, .rejected), (.preparing, .failed),
             (.validating, .ready), (.validating, .preparing), (.validating, .rejected), (.validating, .failed),
             (.ready, .replacing), (.ready, .rejected), (.ready, .failed),
             (.replacing, .verifying), (.replacing, .failed),
             (.verifying, .deleting), (.verifying, .failed),
             (.deleting, .committed), (.deleting, .duplicateKept),
             (.failed, .proposed):
            return true
        default:
            return false
        }
    }
}

public struct InvalidTransition: Error, Equatable, Sendable {
    public let from: TransactionState
    public let to: TransactionState
}

public struct PreservationTransaction: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let assetId: String
    public let originalBytes: Int64
    public private(set) var state: TransactionState
    public var plan: CompressionPlan?
    public var rungIndex: Int
    /// A file name inside the staging directory. Never an absolute path: app container paths change.
    public var stagingFile: String?
    public var candidateBytes: Int64?
    public var finding: ValidationFinding?
    public var replacementId: String?
    public var note: String?
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public init(id: String, assetId: String, originalBytes: Int64, plan: CompressionPlan?, at date: Date) {
        self.id = id
        self.assetId = assetId
        self.originalBytes = originalBytes
        self.state = .proposed
        self.plan = plan
        self.rungIndex = 0
        self.createdAt = date
        self.updatedAt = date
    }

    public mutating func move(to next: TransactionState, at date: Date, note: String? = nil) throws {
        guard state.canMove(to: next) else { throw InvalidTransition(from: state, to: next) }
        state = next
        updatedAt = date
        if let note { self.note = note }
    }
}

public struct AuditEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: Int64
    public let at: Date
    public let event: String
    public let assetId: String?
    public let detail: String

    public init(id: Int64 = 0, at: Date, event: String, assetId: String? = nil, detail: String = "") {
        self.id = id
        self.at = at
        self.event = event
        self.assetId = assetId
        self.detail = detail
    }
}
