import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public final class NoteStore {
    private let database: OpaquePointer
    public let fileURL: URL

    /// Posted only when syncable note content changes. Device-local window
    /// state and font size do not trigger a sync.
    public static let contentDidChangeNotification = Notification.Name("IvyNoteStoreContentDidChange")

    /// `~/Library/Application Support/Ivy/notes.sqlite`.
    public convenience init(fileManager: FileManager = .default) throws {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = applicationSupport.appendingPathComponent("Ivy", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try self.init(fileURL: directory.appendingPathComponent("notes.sqlite"))
    }

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        database = try Self.openDatabase(at: fileURL)
    }

    deinit {
        sqlite3_close_v2(database)
    }

    private static func openDatabase(at fileURL: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            fileURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw NoteStoreError(message: "Could not open \(fileURL.lastPathComponent)", code: status)
        }
        for statement in schemaStatements {
            let result = sqlite3_exec(handle, statement, nil, nil, nil)
            guard result == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(handle))
                sqlite3_close_v2(handle)
                throw NoteStoreError(message: message, code: result)
            }
        }
        do {
            try migrateColumns(handle)
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        return handle
    }

    private static let schemaStatements = [
        "PRAGMA journal_mode = WAL",
        """
        CREATE TABLE IF NOT EXISTS notes (
            uuid TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            color TEXT NOT NULL,
            images TEXT NOT NULL,
            type TEXT NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL,
            dirty INTEGER NOT NULL,
            frame_x REAL,
            frame_y REAL,
            frame_w REAL,
            frame_h REAL,
            window_level TEXT NOT NULL DEFAULT 'normal',
            window_opacity REAL NOT NULL DEFAULT 1.0,
            closed INTEGER NOT NULL DEFAULT 0,
            attachments TEXT NOT NULL DEFAULT '[]',
            font_size REAL NOT NULL DEFAULT 14.0
        )
        """,
        "CREATE INDEX IF NOT EXISTS notes_updated_at ON notes(updated_at)",
        "CREATE INDEX IF NOT EXISTS notes_dirty ON notes(dirty)"
    ]

    /// Device-local note-state columns arrived after the first schema; older
    /// databases gain them in place. These values never enter the sync payload.
    private static let columnMigrations: [(column: String, ddl: String)] = [
        ("frame_x", "ALTER TABLE notes ADD COLUMN frame_x REAL"),
        ("frame_y", "ALTER TABLE notes ADD COLUMN frame_y REAL"),
        ("frame_w", "ALTER TABLE notes ADD COLUMN frame_w REAL"),
        ("frame_h", "ALTER TABLE notes ADD COLUMN frame_h REAL"),
        ("window_level", "ALTER TABLE notes ADD COLUMN window_level TEXT NOT NULL DEFAULT 'normal'"),
        ("window_opacity", "ALTER TABLE notes ADD COLUMN window_opacity REAL NOT NULL DEFAULT 1.0"),
        ("closed", "ALTER TABLE notes ADD COLUMN closed INTEGER NOT NULL DEFAULT 0"),
        ("attachments", "ALTER TABLE notes ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]'"),
        ("font_size", "ALTER TABLE notes ADD COLUMN font_size REAL NOT NULL DEFAULT 14.0")
    ]

    private static func migrateColumns(_ handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, "PRAGMA table_info(notes)", -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw NoteStoreError(message: String(cString: sqlite3_errmsg(handle)), code: status)
        }
        var existing = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                existing.insert(String(cString: name))
            }
        }
        sqlite3_finalize(statement)
        for migration in columnMigrations where !existing.contains(migration.column) {
            let result = sqlite3_exec(handle, migration.ddl, nil, nil, nil)
            guard result == SQLITE_OK else {
                throw NoteStoreError(message: String(cString: sqlite3_errmsg(handle)), code: result)
            }
        }
        let levelMigration = sqlite3_exec(
            handle,
            "UPDATE notes SET window_level = 'normal' WHERE window_level = 'desktop'",
            nil,
            nil,
            nil
        )
        guard levelMigration == SQLITE_OK else {
            throw NoteStoreError(message: String(cString: sqlite3_errmsg(handle)), code: levelMigration)
        }
    }

    @discardableResult
    public func create(
        text: String = "",
        color: String = NoteColor.white.rawValue,
        images: [String] = [],
        attachments: [NoteAttachment] = [],
        type: String = "text",
        now: Date = Date()
    ) throws -> NoteRecord {
        let note = NoteRecord(
            text: text,
            color: NoteColor.allowedRawValues.contains(color) ? color : NoteColor.white.rawValue,
            images: images,
            attachments: attachments,
            type: type,
            updatedAt: now,
            dirty: true
        )
        try save(note)
        return note
    }

    public func save(_ note: NoteRecord) throws {
        try write(note)
        notifyContentChanged()
    }

    private func write(_ note: NoteRecord) throws {
        try withStatement(
            """
            INSERT INTO notes (
                uuid, text, color, images, type, updated_at, deleted_at, dirty,
                frame_x, frame_y, frame_w, frame_h, window_level, window_opacity, closed,
                attachments, font_size
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
            ON CONFLICT(uuid) DO UPDATE SET
                text = excluded.text,
                color = excluded.color,
                images = excluded.images,
                attachments = excluded.attachments,
                type = excluded.type,
                updated_at = excluded.updated_at,
                deleted_at = excluded.deleted_at,
                dirty = excluded.dirty,
                frame_x = excluded.frame_x,
                frame_y = excluded.frame_y,
                frame_w = excluded.frame_w,
                frame_h = excluded.frame_h,
                window_level = excluded.window_level,
                window_opacity = excluded.window_opacity,
                closed = excluded.closed,
                font_size = excluded.font_size
            """
        ) { statement in
            try bind(note, to: statement)
            try step(statement)
        }
    }

    public func update(
        id: String,
        text: String,
        color: String? = nil,
        images: [String]? = nil,
        attachments: [NoteAttachment]? = nil,
        type: String? = nil,
        now: Date = Date()
    ) throws -> NoteRecord? {
        guard var note = try note(id: id) else { return nil }
        note.text = text
        if let color {
            note.color = NoteColor.allowedRawValues.contains(color) ? color : NoteColor.white.rawValue
        }
        if let images { note.images = images }
        if let attachments { note.attachments = attachments }
        if let type { note.type = type }
        note.updatedAt = now
        note.deletedAt = nil
        note.dirty = true
        try save(note)
        return note
    }

    public func delete(id: String, now: Date = Date()) throws {
        guard var note = try note(id: id) else { return }
        note.updatedAt = now
        note.deletedAt = now
        note.dirty = true
        try save(note)
    }

    public func note(id: String) throws -> NoteRecord? {
        try fetch(
            sql: "\(Self.selectColumns) WHERE uuid = ?1 LIMIT 1"
        ) { statement in
            try self.bind(statement, 1, id)
        }.first
    }

    public func fetchAll(includeDeleted: Bool = false) throws -> [NoteRecord] {
        if includeDeleted {
            return try fetch(sql: "\(Self.selectColumns) ORDER BY updated_at DESC") { _ in }
        }
        return try fetch(
            sql: "\(Self.selectColumns) WHERE deleted_at IS NULL ORDER BY updated_at DESC"
        ) { _ in }
    }

    public func fetchDirty() throws -> [NoteRecord] {
        try fetch(sql: "\(Self.selectColumns) WHERE dirty = 1 ORDER BY updated_at ASC") { _ in }
    }

    /// Persists device-local note state without touching `updatedAt`/`dirty`:
    /// moving, pinning, resizing text, or closing a panel is not a content edit
    /// and must not sync.
    @discardableResult
    public func updateWindowState(
        id: String,
        frame: NoteWindowFrame? = nil,
        level: NoteWindowLevel? = nil,
        opacity: Double? = nil,
        fontSize: Double? = nil,
        closed: Bool? = nil
    ) throws -> NoteRecord? {
        guard var note = try note(id: id) else { return nil }
        if let frame { note.windowFrame = frame }
        if let level { note.windowLevel = level }
        if let opacity { note.windowOpacity = Self.normalizedOpacity(opacity) }
        if let fontSize { note.fontSize = Self.normalizedFontSize(fontSize) }
        if let closed { note.closed = closed }
        try write(note)
        return note
    }

    public func applyServerChange(_ incoming: NoteRecord) throws {
        var serverRecord = incoming
        if let local = try note(id: incoming.id) {
            if local.updatedAt > incoming.updatedAt { return }
            // Server payloads never carry device-local note state; keep ours.
            serverRecord.windowFrame = local.windowFrame
            serverRecord.windowLevel = local.windowLevel
            serverRecord.windowOpacity = local.windowOpacity
            serverRecord.fontSize = local.fontSize
            serverRecord.closed = local.closed
        }
        serverRecord.dirty = false
        try write(serverRecord)
    }

    public func markClean(ids: [String]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids {
                try withStatement("UPDATE notes SET dirty = 0 WHERE uuid = ?1") { statement in
                    try bind(statement, 1, id)
                    try step(statement)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Exports one portable SQLite database containing only syncable note data.
    /// Device-local window and font state never enter the payload.
    public func makeSyncSnapshot(at destinationURL: URL) throws {
        try? FileManager.default.removeItem(at: destinationURL)

        var destination: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let destination else {
            if let destination { sqlite3_close_v2(destination) }
            throw NoteStoreError(message: "Could not create sync snapshot", code: openStatus)
        }
        defer { sqlite3_close_v2(destination) }

        let schema = """
        PRAGMA journal_mode = DELETE;
        CREATE TABLE notes (
            uuid TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            color TEXT NOT NULL,
            images TEXT NOT NULL,
            type TEXT NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL,
            attachments TEXT NOT NULL DEFAULT '[]'
        );
        CREATE INDEX notes_updated_at ON notes(updated_at);
        """
        guard sqlite3_exec(destination, schema, nil, nil, nil) == SQLITE_OK else {
            throw Self.databaseError(destination, code: sqlite3_errcode(destination))
        }

        var sourceStatement: OpaquePointer?
        var destinationStatement: OpaquePointer?
        let sourceSQL = """
            SELECT uuid, text, color, images, type, updated_at, deleted_at, attachments
            FROM notes ORDER BY uuid
            """
        let insertSQL = "INSERT INTO notes VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"
        try check(sqlite3_prepare_v2(database, sourceSQL, -1, &sourceStatement, nil))
        guard let sourceStatement else { throw error(SQLITE_ERROR) }
        defer { sqlite3_finalize(sourceStatement) }
        let prepareDestination = sqlite3_prepare_v2(destination, insertSQL, -1, &destinationStatement, nil)
        guard prepareDestination == SQLITE_OK, let destinationStatement else {
            throw Self.databaseError(destination, code: prepareDestination)
        }
        defer { sqlite3_finalize(destinationStatement) }

        guard sqlite3_exec(destination, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw Self.databaseError(destination, code: sqlite3_errcode(destination))
        }
        do {
            while true {
                let sourceStatus = sqlite3_step(sourceStatement)
                if sourceStatus == SQLITE_DONE { break }
                guard sourceStatus == SQLITE_ROW else { throw error(sourceStatus) }
                sqlite3_reset(destinationStatement)
                sqlite3_clear_bindings(destinationStatement)
                for index: Int32 in 0...4 {
                    let value = Self.text(sourceStatement, index)
                    try Self.checkDestination(
                        sqlite3_bind_text(destinationStatement, index + 1, value, -1, SQLITE_TRANSIENT),
                        destination
                    )
                }
                try Self.checkDestination(
                    sqlite3_bind_double(destinationStatement, 6, sqlite3_column_double(sourceStatement, 5)),
                    destination
                )
                if sqlite3_column_type(sourceStatement, 6) == SQLITE_NULL {
                    try Self.checkDestination(sqlite3_bind_null(destinationStatement, 7), destination)
                } else {
                    try Self.checkDestination(
                        sqlite3_bind_double(destinationStatement, 7, sqlite3_column_double(sourceStatement, 6)),
                        destination
                    )
                }
                try Self.checkDestination(
                    sqlite3_bind_text(destinationStatement, 8, Self.text(sourceStatement, 7), -1, SQLITE_TRANSIENT),
                    destination
                )
                guard sqlite3_step(destinationStatement) == SQLITE_DONE else {
                    throw Self.databaseError(destination, code: sqlite3_errcode(destination))
                }
            }
            guard sqlite3_exec(destination, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw Self.databaseError(destination, code: sqlite3_errcode(destination))
            }
        } catch {
            sqlite3_exec(destination, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Reads every row of a portable snapshot database as a clean record.
    /// Device-local state stays at defaults; callers graft it back as needed.
    private static func readSnapshot(at snapshotURL: URL) throws -> [NoteRecord] {
        var source: OpaquePointer?
        let openStatus = sqlite3_open_v2(snapshotURL.path, &source, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let source else {
            if let source { sqlite3_close_v2(source) }
            throw NoteStoreError(message: "Could not open sync snapshot", code: openStatus)
        }
        defer { sqlite3_close_v2(source) }

        // Snapshots uploaded by app versions that predate attachments have no
        // such column; read them as attachment-free rather than failing sync.
        let snapshotHasAttachments = try tableHasColumn(source, table: "notes", column: "attachments")
        var statement: OpaquePointer?
        let sql = snapshotHasAttachments
            ? """
              SELECT uuid, text, color, images, type, updated_at, deleted_at, attachments
              FROM notes ORDER BY updated_at
              """
            : "SELECT uuid, text, color, images, type, updated_at, deleted_at FROM notes ORDER BY updated_at"
        let prepareStatus = sqlite3_prepare_v2(source, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            throw Self.databaseError(source, code: prepareStatus)
        }
        defer { sqlite3_finalize(statement) }

        var incoming: [NoteRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw Self.databaseError(source, code: status) }
            incoming.append(NoteRecord(
                id: Self.text(statement, 0),
                text: Self.text(statement, 1),
                color: Self.text(statement, 2),
                images: try Self.images(from: Self.text(statement, 3)),
                attachments: snapshotHasAttachments ? Self.attachments(from: Self.text(statement, 7)) : [],
                type: Self.text(statement, 4),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                deletedAt: sqlite3_column_type(statement, 6) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                dirty: false
            ))
        }
        return incoming
    }

    /// Replaces syncable note content from a portable database while retaining
    /// this Mac's local window and font state for note IDs it already knows.
    /// Only safe when no local note is dirty; otherwise use `mergeContent(from:)`.
    public func replaceContent(from snapshotURL: URL) throws {
        let localState = Dictionary(uniqueKeysWithValues: try fetchAll(includeDeleted: true).map {
            ($0.id, ($0.windowFrame, $0.windowLevel, $0.windowOpacity, $0.fontSize, $0.closed))
        })
        var incoming = try Self.readSnapshot(at: snapshotURL)
        for index in incoming.indices {
            guard let state = localState[incoming[index].id] else { continue }
            incoming[index].windowFrame = state.0
            incoming[index].windowLevel = state.1
            incoming[index].windowOpacity = state.2
            incoming[index].fontSize = state.3
            incoming[index].closed = state.4
        }

        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM notes")
            for note in incoming { try write(note) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Merges a portable snapshot into the local database, one note at a time,
    /// with last-writer-wins per note: rows whose local `updatedAt` is newer
    /// stay untouched (and stay dirty, so the next upload carries them);
    /// everything else adopts the snapshot row. Deletions travel as
    /// `deleted_at` tombstones, and notes that exist only locally survive.
    public func mergeContent(from snapshotURL: URL) throws {
        let incoming = try Self.readSnapshot(at: snapshotURL)
        try execute("BEGIN IMMEDIATE")
        do {
            for record in incoming { try applyServerChange(record) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func hasDirtyNotes() throws -> Bool {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, "SELECT 1 FROM notes WHERE dirty = 1 LIMIT 1", -1, &statement, nil))
        guard let statement else { throw error(SQLITE_ERROR) }
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let status: throw error(status)
        }
    }

    /// Clears dirty flags only for notes still at the `updatedAt` each record
    /// carried when its snapshot was made; notes edited mid-upload keep their
    /// dirty flag and ride the next sync.
    public func markClean(upToDateWith records: [NoteRecord]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for record in records {
                try withStatement("UPDATE notes SET dirty = 0 WHERE uuid = ?1 AND updated_at = ?2") { statement in
                    try bind(statement, 1, record.id)
                    try check(sqlite3_bind_double(statement, 2, record.updatedAt.timeIntervalSince1970))
                    try step(statement)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func syncSnapshotSizeBytes() throws -> Int64 {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotURL = directory.appendingPathComponent("notes.sqlite")
        try makeSyncSnapshot(at: snapshotURL)
        let values = try snapshotURL.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private static let selectColumns = """
        SELECT uuid, text, color, images, type, updated_at, deleted_at, dirty,
               frame_x, frame_y, frame_w, frame_h, window_level, window_opacity, closed,
               attachments, font_size
        FROM notes
        """

    private func fetch(
        sql: String,
        bindings: (OpaquePointer) throws -> Void
    ) throws -> [NoteRecord] {
        var results: [NoteRecord] = []
        try withStatement(sql) { statement in
            try bindings(statement)
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw error(status) }
                results.append(try Self.note(from: statement))
            }
        }
        return results
    }

    private func bind(_ note: NoteRecord, to statement: OpaquePointer) throws {
        try bind(statement, 1, note.id)
        try bind(statement, 2, note.text)
        try bind(statement, 3, note.color)
        try bind(statement, 4, Self.imagesJSON(note.images))
        try bind(statement, 5, note.type)
        try check(sqlite3_bind_double(statement, 6, note.updatedAt.timeIntervalSince1970))
        if let deletedAt = note.deletedAt {
            try check(sqlite3_bind_double(statement, 7, deletedAt.timeIntervalSince1970))
        } else {
            try check(sqlite3_bind_null(statement, 7))
        }
        try check(sqlite3_bind_int(statement, 8, note.dirty ? 1 : 0))
        if let frame = note.windowFrame {
            try check(sqlite3_bind_double(statement, 9, frame.x))
            try check(sqlite3_bind_double(statement, 10, frame.y))
            try check(sqlite3_bind_double(statement, 11, frame.width))
            try check(sqlite3_bind_double(statement, 12, frame.height))
        } else {
            for index: Int32 in 9...12 {
                try check(sqlite3_bind_null(statement, index))
            }
        }
        try bind(statement, 13, note.windowLevel.rawValue)
        try check(sqlite3_bind_double(statement, 14, Self.normalizedOpacity(note.windowOpacity)))
        try check(sqlite3_bind_int(statement, 15, note.closed ? 1 : 0))
        try bind(statement, 16, Self.attachmentsJSON(note.attachments))
        try check(sqlite3_bind_double(statement, 17, Self.normalizedFontSize(note.fontSize)))
    }

    private static func note(from statement: OpaquePointer) throws -> NoteRecord {
        let deletedAt: Date?
        if sqlite3_column_type(statement, 6) == SQLITE_NULL {
            deletedAt = nil
        } else {
            deletedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        }
        var windowFrame: NoteWindowFrame?
        if sqlite3_column_type(statement, 8) != SQLITE_NULL,
           sqlite3_column_type(statement, 10) != SQLITE_NULL {
            windowFrame = NoteWindowFrame(
                x: sqlite3_column_double(statement, 8),
                y: sqlite3_column_double(statement, 9),
                width: sqlite3_column_double(statement, 10),
                height: sqlite3_column_double(statement, 11)
            )
        }
        return NoteRecord(
            id: text(statement, 0),
            text: text(statement, 1),
            color: text(statement, 2),
            images: try images(from: text(statement, 3)),
            attachments: attachments(from: text(statement, 15)),
            type: text(statement, 4),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            deletedAt: deletedAt,
            dirty: sqlite3_column_int(statement, 7) != 0,
            windowFrame: windowFrame,
            windowLevel: NoteWindowLevel.value(for: text(statement, 12)),
            windowOpacity: normalizedOpacity(sqlite3_column_double(statement, 13)),
            fontSize: normalizedFontSize(sqlite3_column_double(statement, 16)),
            closed: sqlite3_column_int(statement, 14) != 0
        )
    }

    private static func normalizedOpacity(_ opacity: Double) -> Double {
        min(max(opacity, 0.1), 1)
    }

    private static func normalizedFontSize(_ fontSize: Double) -> Double {
        min(max(fontSize, NoteRecord.minimumFontSize), NoteRecord.maximumFontSize)
    }

    private static func imagesJSON(_ images: [String]) throws -> String {
        let data = try JSONEncoder().encode(images)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func images(from json: String) throws -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([String].self, from: data)
    }

    private static func attachmentsJSON(_ attachments: [NoteAttachment]) -> String {
        guard let data = try? JSONEncoder().encode(attachments) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Attachment JSON written by newer app versions may carry unknown fields;
    /// anything undecodable degrades to "no attachments" instead of failing
    /// the whole note load.
    private static func attachments(from json: String) -> [NoteAttachment] {
        guard
            !json.isEmpty,
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([NoteAttachment].self, from: data)
        else { return [] }
        return decoded
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: bytes)
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
        guard let statement else { throw error(SQLITE_ERROR) }
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(database, sql, nil, nil, nil))
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) throws {
        try check(sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT))
    }

    private func step(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw error(status) }
    }

    private func check(_ status: Int32) throws {
        guard status == SQLITE_OK else { throw error(status) }
    }

    private func error(_ code: Int32) -> NoteStoreError {
        NoteStoreError(message: String(cString: sqlite3_errmsg(database)), code: code)
    }

    private func notifyContentChanged() {
        NotificationCenter.default.post(name: Self.contentDidChangeNotification, object: self)
    }

    private static func tableHasColumn(_ handle: OpaquePointer, table: String, column: String) throws -> Bool {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw databaseError(handle, code: status)
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column { return true }
        }
        return false
    }

    private static func checkDestination(_ status: Int32, _ database: OpaquePointer) throws {
        guard status == SQLITE_OK else { throw databaseError(database, code: status) }
    }

    private static func databaseError(_ database: OpaquePointer, code: Int32) -> NoteStoreError {
        NoteStoreError(message: String(cString: sqlite3_errmsg(database)), code: code)
    }
}

public struct NoteStoreError: LocalizedError, Sendable {
    public let message: String
    public let code: Int32

    public var errorDescription: String? {
        "Ivy notes database error \(code): \(message)"
    }
}

/// `SQLITE_TRANSIENT` is a function-pointer sentinel the SQLite headers define
/// as a cast that Swift cannot import.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
