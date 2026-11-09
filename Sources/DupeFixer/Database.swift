import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteValue {
    case text(String)
    case integer(Int64)
    case real(Double)
    case blob(Data)
    case null
}

struct SQLiteRow {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func string(_ key: String) -> String { values[key] ?? "" }
    func optionalString(_ key: String) -> String? { values[key] }
    func integer(_ key: String) -> Int64 { Int64(values[key] ?? "") ?? 0 }
    func double(_ key: String) -> Double { Double(values[key] ?? "") ?? 0 }
    func optionalDouble(_ key: String) -> Double? { values[key].flatMap(Double.init) }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(database)
            throw DupeFixerError.database(message)
        }
        handle = database
        sqlite3_busy_timeout(database, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try createSchema()
    }

    deinit {
        sqlite3_close(handle)
    }

    @discardableResult
    func execute(_ sql: String, arguments: [SQLiteValue] = []) throws -> Int32 {
        guard let handle else { throw DupeFixerError.database("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        try bind(arguments, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw lastError() }
        return result
    }

    func query(_ sql: String, arguments: [SQLiteValue] = []) throws -> [SQLiteRow] {
        guard let handle else { throw DupeFixerError.database("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        try bind(arguments, to: statement)

        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw lastError() }
            var values: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let namePointer = sqlite3_column_name(statement, index) else { continue }
                let name = String(cString: namePointer)
                if sqlite3_column_type(statement, index) == SQLITE_NULL {
                    continue
                }
                if let pointer = sqlite3_column_text(statement, index) {
                    values[name] = String(cString: pointer)
                } else {
                    values[name] = String(sqlite3_column_int64(statement, index))
                }
            }
            rows.append(SQLiteRow(values: values))
        }
        return rows
    }

    var lastInsertRowID: Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    func begin() throws { try execute("BEGIN IMMEDIATE TRANSACTION") }
    func commit() throws { try execute("COMMIT") }
    func rollback() { _ = try? execute("ROLLBACK") }

    private func bind(_ arguments: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch argument {
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .blob(let value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransient)
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw lastError() }
        }
    }

    private func lastError() -> DupeFixerError {
        guard let handle else { return .database("unknown SQLite error") }
        return .database(String(cString: sqlite3_errmsg(handle)))
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS scans (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at REAL NOT NULL,
            finished_at REAL,
            status TEXT NOT NULL,
            mode TEXT NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            UNIQUE(scan_id, path)
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            name TEXT NOT NULL,
            extension TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_at REAL,
            created_at REAL,
            content_type TEXT NOT NULL,
            normalized_name TEXT NOT NULL,
            is_image INTEGER NOT NULL,
            is_document INTEGER NOT NULL,
            is_office_archive INTEGER NOT NULL,
            partial_sha256 TEXT,
            sha256 TEXT,
            image_digest TEXT,
            extracted_text TEXT,
            UNIQUE(scan_id, path)
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS candidates (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
            group_id INTEGER NOT NULL,
            left_file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            right_file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            score REAL NOT NULL,
            evidence_json TEXT NOT NULL,
            UNIQUE(scan_id, left_file_id, right_file_id)
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS decisions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
            group_id INTEGER NOT NULL,
            decision TEXT NOT NULL,
            canonical_path TEXT,
            decided_at REAL NOT NULL,
            UNIQUE(scan_id, group_id)
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS deletions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
            group_id INTEGER NOT NULL,
            path TEXT NOT NULL,
            original_sha256 TEXT,
            moved_to_trash INTEGER NOT NULL,
            error TEXT,
            attempted_at REAL NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS junk_findings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            reason TEXT NOT NULL,
            confidence REAL NOT NULL,
            UNIQUE(scan_id, file_id, reason)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS files_scan_size ON files(scan_id, size)")
        try execute("CREATE INDEX IF NOT EXISTS files_scan_name ON files(scan_id, normalized_name)")
        try execute("CREATE INDEX IF NOT EXISTS candidates_scan_group ON candidates(scan_id, group_id)")
    }

    func startScan(mode: AnalysisMode, resume: Bool) throws -> Int64 {
        if resume, let existing = try query("SELECT id FROM scans WHERE status IN ('running', 'failed') ORDER BY id DESC LIMIT 1").first?.integer("id") {
            try execute("UPDATE scans SET started_at = ?, finished_at = NULL, status = 'running', mode = ? WHERE id = ?", arguments: [.real(Date().timeIntervalSince1970), .text(mode.rawValue), .integer(existing)])
            return existing
        }
        try execute("INSERT INTO scans(started_at, status, mode) VALUES(?, 'running', ?)", arguments: [.real(Date().timeIntervalSince1970), .text(mode.rawValue)])
        return lastInsertRowID
    }

    func finishScan(_ scanID: Int64, status: String) throws {
        try execute("UPDATE scans SET finished_at = ?, status = ? WHERE id = ?", arguments: [.real(Date().timeIntervalSince1970), .text(status), .integer(scanID)])
    }

    func saveFolder(_ folder: DiscoveredFolder, scanID: Int64) throws {
        try execute("INSERT OR IGNORE INTO folders(scan_id, path, relative_path) VALUES(?, ?, ?)", arguments: [.integer(scanID), .text(folder.path), .text(folder.relativePath)])
    }

    @discardableResult
    func saveFile(_ file: DiscoveredFile, scanID: Int64) throws -> Int64 {
        try execute("""
        INSERT OR REPLACE INTO files(scan_id, path, relative_path, name, extension, size, modified_at, created_at, content_type, normalized_name, is_image, is_document, is_office_archive)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            .integer(scanID), .text(file.path), .text(file.relativePath), .text(file.name), .text(file.fileExtension), .integer(file.size),
            file.modifiedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            file.createdAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            .text(file.contentType), .text(file.normalizedName), .integer(file.isImage ? 1 : 0), .integer(file.isDocument ? 1 : 0), .integer(file.isArchiveOfficeDocument ? 1 : 0)
        ])
        let rows = try query("SELECT id FROM files WHERE scan_id = ? AND path = ?", arguments: [.integer(scanID), .text(file.path)])
        return rows.first?.integer("id") ?? 0
    }

    func updateFingerprint(_ fingerprint: FileFingerprint, fileID: Int64) throws {
        try execute("UPDATE files SET partial_sha256 = ?, sha256 = ?, image_digest = ?, extracted_text = ? WHERE id = ?", arguments: [
            fingerprint.partialSHA256.map(SQLiteValue.text) ?? .null,
            fingerprint.sha256.map(SQLiteValue.text) ?? .null,
            fingerprint.imageDigest.map(SQLiteValue.text) ?? .null,
            fingerprint.extractedText.map(SQLiteValue.text) ?? .null,
            .integer(fileID)
        ])
    }

    func clearCandidates(scanID: Int64) throws {
        try execute("DELETE FROM candidates WHERE scan_id = ?", arguments: [.integer(scanID)])
        try execute("DELETE FROM decisions WHERE scan_id = ?", arguments: [.integer(scanID)])
    }

    func clearJunkFindings(scanID: Int64) throws {
        try execute("DELETE FROM junk_findings WHERE scan_id = ?", arguments: [.integer(scanID)])
    }

    func resetScanContents(scanID: Int64) throws {
        try execute("DELETE FROM candidates WHERE scan_id = ?", arguments: [.integer(scanID)])
        try execute("DELETE FROM decisions WHERE scan_id = ?", arguments: [.integer(scanID)])
        try execute("DELETE FROM junk_findings WHERE scan_id = ?", arguments: [.integer(scanID)])
        try execute("DELETE FROM folders WHERE scan_id = ?", arguments: [.integer(scanID)])
        try execute("DELETE FROM files WHERE scan_id = ?", arguments: [.integer(scanID)])
    }

    func saveCandidate(_ candidate: DuplicateCandidate, scanID: Int64) throws {
        let data = try JSONEncoder().encode(candidate.evidence)
        let evidence = String(decoding: data, as: UTF8.self)
        try execute("INSERT OR REPLACE INTO candidates(scan_id, group_id, left_file_id, right_file_id, score, evidence_json) VALUES(?, ?, ?, ?, ?, ?)", arguments: [
            .integer(scanID), .integer(candidate.groupID), .integer(candidate.left.idForPersistence), .integer(candidate.right.idForPersistence), .real(candidate.score), .text(evidence)
        ])
    }

    func saveDecision(_ record: ReviewRecord, scanID: Int64) throws {
        try execute("""
        INSERT INTO decisions(scan_id, group_id, decision, canonical_path, decided_at) VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(scan_id, group_id) DO UPDATE SET decision = excluded.decision, canonical_path = excluded.canonical_path, decided_at = excluded.decided_at
        """, arguments: [.integer(scanID), .integer(record.groupID), .text(record.decision.rawValue), record.canonicalPath.map(SQLiteValue.text) ?? .null, .real(Date().timeIntervalSince1970)])
    }

    func decisions(scanID: Int64) throws -> [ReviewRecord] {
        try query("SELECT group_id, decision, canonical_path FROM decisions WHERE scan_id = ?", arguments: [.integer(scanID)]).compactMap { row in
            guard let decision = ReviewDecision(rawValue: row.string("decision")) else { return nil }
            return ReviewRecord(groupID: row.integer("group_id"), decision: decision, canonicalPath: row.optionalString("canonical_path"))
        }
    }

    func recordDeletion(scanID: Int64, groupID: Int64, path: String, originalSHA256: String?, result: DeletionResult) throws {
        try execute("INSERT INTO deletions(scan_id, group_id, path, original_sha256, moved_to_trash, error, attempted_at) VALUES(?, ?, ?, ?, ?, ?, ?)", arguments: [
            .integer(scanID), .integer(groupID), .text(path), originalSHA256.map(SQLiteValue.text) ?? .null, .integer(result.movedToTrash ? 1 : 0), result.error.map(SQLiteValue.text) ?? .null, .real(Date().timeIntervalSince1970)
        ])
    }

    func saveJunkFinding(_ finding: JunkFinding, scanID: Int64) throws {
        try execute("INSERT OR REPLACE INTO junk_findings(scan_id, file_id, reason, confidence) VALUES(?, ?, ?, ?)", arguments: [.integer(scanID), .integer(finding.file.id), .text(finding.reason), .real(finding.confidence)])
    }

    func junkFindings(scanID: Int64) throws -> [(path: String, reason: String, confidence: Double)] {
        try query("SELECT f.relative_path, j.reason, j.confidence FROM junk_findings j JOIN files f ON f.id = j.file_id WHERE j.scan_id = ? ORDER BY j.confidence DESC, f.relative_path", arguments: [.integer(scanID)]).map {
            (path: $0.string("relative_path"), reason: $0.string("reason"), confidence: $0.double("confidence"))
        }
    }

    func loadGroups(scanID: Int64) throws -> [DuplicateGroup] {
        let rows = try query("""
        SELECT c.id AS candidate_id, c.group_id, c.score, c.evidence_json,
               l.id AS left_id, l.path AS left_path, l.relative_path AS left_relative_path, l.name AS left_name, l.extension AS left_extension,
               l.size AS left_size, l.modified_at AS left_modified_at, l.created_at AS left_created_at, l.content_type AS left_content_type,
               l.normalized_name AS left_normalized_name, l.is_image AS left_is_image, l.is_document AS left_is_document, l.is_office_archive AS left_is_office_archive, l.sha256 AS left_sha256,
               r.id AS right_id, r.path AS right_path, r.relative_path AS right_relative_path, r.name AS right_name, r.extension AS right_extension,
               r.size AS right_size, r.modified_at AS right_modified_at, r.created_at AS right_created_at, r.content_type AS right_content_type,
               r.normalized_name AS right_normalized_name, r.is_image AS right_is_image, r.is_document AS right_is_document, r.is_office_archive AS right_is_office_archive, r.sha256 AS right_sha256
        FROM candidates c
        JOIN files l ON l.id = c.left_file_id
        JOIN files r ON r.id = c.right_file_id
        WHERE c.scan_id = ?
        ORDER BY c.group_id, c.score DESC
        """, arguments: [.integer(scanID)])

        var grouped: [Int64: [DuplicateCandidate]] = [:]
        for row in rows {
            guard let evidenceData = row.string("evidence_json").data(using: .utf8), let evidence = try? JSONDecoder().decode(AnalysisEvidence.self, from: evidenceData) else { continue }
            let left = file(from: row, side: "left")
            let right = file(from: row, side: "right")
            let candidate = DuplicateCandidate(id: row.integer("candidate_id"), left: left, right: right, evidence: evidence, groupID: row.integer("group_id"))
            grouped[candidate.groupID, default: []].append(candidate)
        }
        return grouped.keys.sorted().compactMap { id in
            guard let candidates = grouped[id], !candidates.isEmpty else { return nil }
            return DuplicateGroup(id: id, candidates: candidates)
        }
    }

    func latestScan() throws -> Int64? {
        try query("SELECT id FROM scans ORDER BY id DESC LIMIT 1").first?.integer("id")
    }

    func scanSummary(scanID: Int64) throws -> (files: Int, candidates: Int, decisions: Int, deletions: Int, junk: Int) {
        func count(_ table: String) throws -> Int {
            Int(try query("SELECT COUNT(*) AS count FROM \(table) WHERE scan_id = ?", arguments: [.integer(scanID)]).first?.integer("count") ?? 0)
        }
        let junk = Int(try query("SELECT COUNT(*) AS count FROM junk_findings WHERE scan_id = ?", arguments: [.integer(scanID)]).first?.integer("count") ?? 0)
        return (try count("files"), try count("candidates"), try count("decisions"), try count("deletions"), junk)
    }

    private func file(from row: SQLiteRow, side: String) -> DiscoveredFile {
        DiscoveredFile(
            id: row.integer("\(side)_id"),
            path: row.string("\(side)_path"),
            relativePath: row.string("\(side)_relative_path"),
            name: row.string("\(side)_name"),
            fileExtension: row.string("\(side)_extension"),
            size: row.integer("\(side)_size"),
            modifiedAt: row.optionalDouble("\(side)_modified_at").map(Date.init(timeIntervalSince1970:)),
            createdAt: row.optionalDouble("\(side)_created_at").map(Date.init(timeIntervalSince1970:)),
            contentType: row.string("\(side)_content_type"),
            normalizedName: row.string("\(side)_normalized_name"),
            isImage: row.integer("\(side)_is_image") == 1,
            isDocument: row.integer("\(side)_is_document") == 1,
            isArchiveOfficeDocument: row.integer("\(side)_is_office_archive") == 1,
            sha256: row.optionalString("\(side)_sha256")
        )
    }
}

private extension DiscoveredFile {
    var idForPersistence: Int64 {
        id
    }
}
