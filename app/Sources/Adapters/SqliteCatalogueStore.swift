import EverKeepCore
import Foundation
import SQLite3

/// SQLite catalogue. Each record is stored as JSON beside the few columns that are queried.
actor SqliteCatalogueStore: CatalogueStore {
    private enum Value {
        case text(String)
        case int(Int64)
        case double(Double)
        case null
    }

    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw AdapterError.catalogue(message)
        }
        database = opened
        try Self.execute(opened, """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS assets (id TEXT PRIMARY KEY, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS decisions (asset_id TEXT PRIMARY KEY, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS transactions (
            id TEXT PRIMARY KEY, asset_id TEXT NOT NULL, state TEXT NOT NULL,
            updated_at REAL NOT NULL, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS protections (asset_id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS audit (
            id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, event TEXT NOT NULL,
            asset_id TEXT, detail TEXT NOT NULL);
        """)
    }

    // MARK: Assets

    func upsert(assets: [MediaAsset]) throws {
        try inTransaction {
            for asset in assets {
                try run("INSERT OR REPLACE INTO assets (id, json) VALUES (?, ?)", [.text(asset.id), .text(try encode(asset))])
            }
        }
    }

    func removeAssets(except ids: Set<String>) throws {
        let stored = try rows("SELECT id FROM assets") { Self.text($0, 0) }
        let stale = stored.filter { !ids.contains($0) }
        guard !stale.isEmpty else { return }
        try inTransaction {
            for id in stale {
                try run("DELETE FROM assets WHERE id = ?", [.text(id)])
                try run("DELETE FROM decisions WHERE asset_id = ?", [.text(id)])
            }
        }
    }

    func asset(id: String) throws -> MediaAsset? {
        try decodeAll(MediaAsset.self, "SELECT json FROM assets WHERE id = ?", [.text(id)]).first
    }

    func allAssets() throws -> [MediaAsset] {
        try decodeAll(MediaAsset.self, "SELECT json FROM assets")
    }

    // MARK: Decisions

    func save(decision: PreservationDecision) throws {
        try run("INSERT OR REPLACE INTO decisions (asset_id, json) VALUES (?, ?)", [.text(decision.assetId), .text(try encode(decision))])
    }

    func decision(for assetId: String) throws -> PreservationDecision? {
        try decodeAll(PreservationDecision.self, "SELECT json FROM decisions WHERE asset_id = ?", [.text(assetId)]).first
    }

    func allDecisions() throws -> [PreservationDecision] {
        try decodeAll(PreservationDecision.self, "SELECT json FROM decisions")
    }

    // MARK: Transactions

    func save(transaction: PreservationTransaction) throws {
        try run(
            "INSERT OR REPLACE INTO transactions (id, asset_id, state, updated_at, json) VALUES (?, ?, ?, ?, ?)",
            [
                .text(transaction.id),
                .text(transaction.assetId),
                .text(transaction.state.rawValue),
                .double(transaction.updatedAt.timeIntervalSince1970),
                .text(try encode(transaction)),
            ]
        )
    }

    func transaction(id: String) throws -> PreservationTransaction? {
        try decodeAll(PreservationTransaction.self, "SELECT json FROM transactions WHERE id = ?", [.text(id)]).first
    }

    func transactions(in states: Set<TransactionState>) throws -> [PreservationTransaction] {
        guard !states.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: states.count).joined(separator: ", ")
        return try decodeAll(
            PreservationTransaction.self,
            "SELECT json FROM transactions WHERE state IN (\(marks)) ORDER BY updated_at",
            states.map { Value.text($0.rawValue) }
        )
    }

    func allTransactions() throws -> [PreservationTransaction] {
        try decodeAll(PreservationTransaction.self, "SELECT json FROM transactions")
    }

    // MARK: Protections and audit

    func protections() throws -> Set<String> {
        Set(try rows("SELECT asset_id FROM protections") { Self.text($0, 0) })
    }

    func setProtected(_ id: String, _ isProtected: Bool) throws {
        if isProtected {
            try run("INSERT OR IGNORE INTO protections (asset_id) VALUES (?)", [.text(id)])
        } else {
            try run("DELETE FROM protections WHERE asset_id = ?", [.text(id)])
        }
    }

    func append(audit entry: AuditEntry) throws {
        let assetValue: Value = entry.assetId.map { Value.text($0) } ?? Value.null
        try run(
            "INSERT INTO audit (at, event, asset_id, detail) VALUES (?, ?, ?, ?)",
            [.double(entry.at.timeIntervalSince1970), .text(entry.event), assetValue, .text(entry.detail)]
        )
    }

    func recentAudit(limit: Int) throws -> [AuditEntry] {
        try rows("SELECT id, at, event, asset_id, detail FROM audit ORDER BY id DESC LIMIT ?", [.int(Int64(limit))]) { statement in
            AuditEntry(
                id: sqlite3_column_int64(statement, 0),
                at: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                event: Self.text(statement, 2),
                assetId: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Self.text(statement, 3),
                detail: Self.text(statement, 4)
            )
        }
    }

    // MARK: SQLite plumbing

    private func inTransaction(_ body: () throws -> Void) throws {
        try run("BEGIN")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decodeAll<T: Decodable>(_ type: T.Type, _ sql: String, _ values: [Value] = []) throws -> [T] {
        let texts = try rows(sql, values) { Self.text($0, 0) }
        return try texts.map { try decoder.decode(type, from: Data($0.utf8)) }
    }

    private func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AdapterError.catalogue(message()) }
    }

    private func rows<T>(_ sql: String, _ values: [Value] = [], map: (OpaquePointer) -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                result.append(map(statement))
            } else if code == SQLITE_DONE {
                return result
            } else {
                throw AdapterError.catalogue(message())
            }
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw AdapterError.catalogue(message())
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(prepared, index, text, -1, Self.transient)
            case .int(let number): sqlite3_bind_int64(prepared, index, number)
            case .double(let number): sqlite3_bind_double(prepared, index, number)
            case .null: sqlite3_bind_null(prepared, index)
            }
        }
        return prepared
    }

    private func message() -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "the database is closed"
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        String(cString: sqlite3_column_text(statement, column))
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorPointer)
            throw AdapterError.catalogue(message)
        }
    }
}
