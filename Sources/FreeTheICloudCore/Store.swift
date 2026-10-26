import Foundation
import CSQLite

/// One JSON record per asset retains optional and source-specific metadata. SQL indexes source identity.
public actor CatalogStore {
    private var db: OpaquePointer?
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw MediaError.message("Could not open the local catalog.") }
        sqlite3_busy_timeout(db, 5000)
        let sql = "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS assets (id TEXT PRIMARY KEY, source TEXT NOT NULL, data BLOB NOT NULL); CREATE INDEX IF NOT EXISTS source_idx ON assets(source); CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, data BLOB NOT NULL);"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db)); sqlite3_close(db); db = nil
            throw MediaError.message(message)
        }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func error() -> MediaError { .message(String(cString: sqlite3_errmsg(db))) }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        return stmt
    }
    private func bind(_ text: String, to stmt: OpaquePointer, at index: Int32) {
        _ = text.withCString { sqlite3_bind_text(stmt, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func bind(_ data: Data, to stmt: OpaquePointer, at index: Int32) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    public func save(_ item: MediaItem) throws {
        let stmt = try statement("INSERT OR REPLACE INTO assets(id,source,data) VALUES(?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(item.id, to: stmt, at: 1); bind(item.sourceID, to: stmt, at: 2)
        bind(try JSONEncoder().encode(item), to: stmt, at: 3)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }
    public func items(source: String) throws -> [MediaItem] {
        let stmt = try statement("SELECT data FROM assets WHERE source=? ORDER BY id")
        defer { sqlite3_finalize(stmt) }
        bind(source, to: stmt, at: 1)
        var result: [MediaItem] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let blob = sqlite3_column_blob(stmt, 0) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
                result.append(try JSONDecoder().decode(MediaItem.self, from: data))
            }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw error() }
        return result
    }
    public func prune(source: String, retaining ids: Set<String>) throws {
        for item in try items(source: source) where !ids.contains(item.id) {
            let stmt = try statement("DELETE FROM assets WHERE id=?")
            bind(item.id, to: stmt, at: 1)
            let status = sqlite3_step(stmt); sqlite3_finalize(stmt)
            guard status == SQLITE_DONE else { throw error() }
        }
    }
    public func savePlan(_ plan: ReviewPlan, source: String) throws {
        let stmt = try statement("INSERT OR REPLACE INTO state(key,data) VALUES(?,?)")
        defer { sqlite3_finalize(stmt) }
        bind("plan:" + source, to: stmt, at: 1); bind(try JSONEncoder().encode(plan), to: stmt, at: 2)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }
    public func plan(source: String) throws -> ReviewPlan {
        let stmt = try statement("SELECT data FROM state WHERE key=?")
        defer { sqlite3_finalize(stmt) }
        bind("plan:" + source, to: stmt, at: 1)
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return ReviewPlan() }
        guard status == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { throw error() }
        return try JSONDecoder().decode(ReviewPlan.self, from: Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0))))
    }
    public func saveExports(_ results: [ExportResult], source: String) throws {
        let stmt = try statement("INSERT OR REPLACE INTO state(key,data) VALUES(?,?)")
        defer { sqlite3_finalize(stmt) }
        bind("exports:" + source, to: stmt, at: 1)
        bind(try JSONEncoder().encode(Array(results.suffix(200))), to: stmt, at: 2)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }
    public func exports(source: String) throws -> [ExportResult] {
        let stmt = try statement("SELECT data FROM state WHERE key=?")
        defer { sqlite3_finalize(stmt) }; bind("exports:" + source, to: stmt, at: 1)
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return [] }
        guard status == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { throw error() }
        return try JSONDecoder().decode([ExportResult].self, from: Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0))))
    }
    public func saveLibraryFailure(_ reason: String?, source: String) throws {
        try saveState(reason, key: "library-failure:" + source)
    }
    public func savePhotoExports(_ results: [PhotoExportResult], source: String) throws {
        try saveState(Array(results.suffix(200)), key: "photo-exports:" + source)
    }
    public func photoExports(source: String) throws -> [PhotoExportResult] {
        try state([PhotoExportResult].self, key: "photo-exports:" + source) ?? []
    }
    public func libraryFailure(source: String) throws -> String? {
        try state(String?.self, key: "library-failure:" + source) ?? nil
    }
    private func saveState<T: Encodable>(_ value: T, key: String) throws {
        let stmt = try statement("INSERT OR REPLACE INTO state(key,data) VALUES(?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(key, to: stmt, at: 1); bind(try JSONEncoder().encode(value), to: stmt, at: 2)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }
    private func state<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        let stmt = try statement("SELECT data FROM state WHERE key=?")
        defer { sqlite3_finalize(stmt) }; bind(key, to: stmt, at: 1)
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { throw error() }
        return try JSONDecoder().decode(type, from: Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0))))
    }
    public func saveSource(_ source: SavedSource, select: Bool = true) throws {
        try saveState(source, key: "source:" + source.id)
        if select { try saveState(source.id, key: "last-source") }
    }
    public func lastSourceID() throws -> String? { try state(String.self, key: "last-source") }
    public func savedSources(demoFolder: URL) throws -> [SavedSource] {
        // Discover pre-v0.4 catalogs without opening any original files or PhotoKit.
        let stmt = try statement("SELECT source FROM assets GROUP BY source UNION SELECT substr(key,8) FROM state WHERE key LIKE 'source:%'")
        defer { sqlite3_finalize(stmt) }
        var ids: [String] = []; var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let value = sqlite3_column_text(stmt, 0) { ids.append(String(cString: value)) }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw error() }
        return try ids.compactMap { id in
            if let saved = try state(SavedSource.self, key: "source:" + id) { return saved }
            if id == "photos:system" { return SavedSource(id: id, name: "System Photo Library", folder: nil, isDemo: false) }
            guard id.hasPrefix("folder:/") else { return nil }
            let folder = URL(fileURLWithPath: String(id.dropFirst("folder:".count)))
            let demo = folder.standardizedFileURL.path == demoFolder.standardizedFileURL.path
            return SavedSource(id: id, name: demo ? "Generated demo" : folder.lastPathComponent, folder: folder, isDemo: demo)
        }.sorted { a, b in
            if a.id == b.id { return false }
            if a.isDemo != b.isDemo { return !a.isDemo }
            if a.id == "photos:system" || b.id == "photos:system" { return a.id == "photos:system" }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    public func saveExportIssues(_ issues: [ExportIssue], source: String) throws {
        try saveState(Array(issues.suffix(200)), key: "export-issues:" + source)
    }
    public func exportIssues(source: String) throws -> [ExportIssue] {
        try state([ExportIssue].self, key: "export-issues:" + source) ?? []
    }
}
