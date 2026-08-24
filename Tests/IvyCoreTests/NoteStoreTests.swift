import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import XCTest
import IvyCore

final class NoteStoreTests: XCTestCase {
    func testCreateUpdateAndDirtyMarking() throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let updatedAt = Date(timeIntervalSince1970: 2_000)

        let created = try fixture.store.create(text: "Buy milk", color: NoteColor.green.rawValue, now: createdAt)

        var loaded = try XCTUnwrap(try fixture.store.note(id: created.id))
        XCTAssertEqual(loaded.text, "Buy milk")
        XCTAssertEqual(loaded.color, NoteColor.green.rawValue)
        XCTAssertEqual(loaded.updatedAt, createdAt)
        XCTAssertTrue(loaded.dirty)

        let updated = try XCTUnwrap(try fixture.store.update(id: created.id, text: "Buy oat milk", now: updatedAt))
        XCTAssertEqual(updated.text, "Buy oat milk")
        XCTAssertEqual(updated.updatedAt, updatedAt)
        XCTAssertTrue(updated.dirty)
        XCTAssertEqual(try fixture.store.fetchDirty().map(\.id), [created.id])

        try fixture.store.markClean(ids: [created.id])
        loaded = try XCTUnwrap(try fixture.store.note(id: created.id))
        XCTAssertFalse(loaded.dirty)
    }

    func testCreateDefaultsToWhiteAndRejectsUnknownColor() throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        let defaulted = try fixture.store.create(text: "Plain note")
        XCTAssertEqual(defaulted.color, NoteColor.white.rawValue)

        let coerced = try fixture.store.create(text: "Bad color", color: "neon")
        XCTAssertEqual(coerced.color, NoteColor.white.rawValue)

        XCTAssertEqual(AppSettings().normalized().defaultNoteColor, NoteColor.white.rawValue)
        XCTAssertEqual(
            AppSettings(defaultNoteColor: "neon").normalized().defaultNoteColor,
            NoteColor.white.rawValue
        )
    }

    func testWindowStateSkipsDirtyAndSurvivesServerChanges() throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }
        let createdAt = Date(timeIntervalSince1970: 1_000)

        let created = try fixture.store.create(text: "Move me", now: createdAt)
        try fixture.store.markClean(ids: [created.id])

        let frame = NoteWindowFrame(x: -1_440, y: 120, width: 320, height: 260)
        let updated = try XCTUnwrap(
            try fixture.store.updateWindowState(
                id: created.id,
                frame: frame,
                level: .pinned,
                opacity: 0.42,
                fontSize: 18,
                closed: true
            )
        )
        XCTAssertEqual(updated.windowFrame, frame)
        XCTAssertEqual(updated.windowLevel, .pinned)
        XCTAssertEqual(updated.windowOpacity, 0.42, accuracy: 0.001)
        XCTAssertEqual(updated.fontSize, 18)
        XCTAssertTrue(updated.closed)
        XCTAssertFalse(updated.dirty)
        XCTAssertEqual(updated.updatedAt, createdAt)
        XCTAssertTrue(try fixture.store.fetchDirty().isEmpty)

        let serverRecord = NoteRecord(
            id: created.id,
            text: "Server edit",
            color: NoteColor.blue.rawValue,
            updatedAt: createdAt.addingTimeInterval(60)
        )
        try fixture.store.applyServerChange(serverRecord)

        let merged = try XCTUnwrap(try fixture.store.note(id: created.id))
        XCTAssertEqual(merged.text, "Server edit")
        XCTAssertEqual(merged.windowFrame, frame)
        XCTAssertEqual(merged.windowLevel, .pinned)
        XCTAssertEqual(merged.windowOpacity, 0.42, accuracy: 0.001)
        XCTAssertEqual(merged.fontSize, 18)
        XCTAssertTrue(merged.closed)
    }

    func testMigratesLegacyDatabaseAddingWindowStateColumns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.sqlite")

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fileURL.path, &handle), SQLITE_OK)
        let legacy = try XCTUnwrap(handle)
        let legacySchema = """
        CREATE TABLE notes (
            uuid TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            color TEXT NOT NULL,
            images TEXT NOT NULL,
            type TEXT NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL,
            dirty INTEGER NOT NULL,
            window_level TEXT NOT NULL DEFAULT 'desktop'
        );
        INSERT INTO notes VALUES ('legacy-id', 'Old note', 'yellow', '[]', 'text', 1000.0, NULL, 1, 'desktop');
        """
        XCTAssertEqual(sqlite3_exec(legacy, legacySchema, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(legacy)

        let store = try NoteStore(fileURL: fileURL)
        let migrated = try XCTUnwrap(try store.note(id: "legacy-id"))
        XCTAssertEqual(migrated.text, "Old note")
        XCTAssertNil(migrated.windowFrame)
        XCTAssertEqual(migrated.windowLevel, .normal)
        XCTAssertEqual(migrated.windowOpacity, 1)
        XCTAssertEqual(migrated.fontSize, NoteRecord.defaultFontSize)
        XCTAssertFalse(migrated.closed)
        XCTAssertTrue(migrated.dirty)
        XCTAssertTrue(migrated.attachments.isEmpty)

        let frame = NoteWindowFrame(x: 10, y: 20, width: 300, height: 200)
        let updated = try XCTUnwrap(try store.updateWindowState(id: "legacy-id", frame: frame))
        XCTAssertEqual(updated.windowFrame, frame)
        XCTAssertEqual(updated.updatedAt, Date(timeIntervalSince1970: 1_000))
    }

    func testTombstoneRoundtripAndServerChangeApplication() throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let deletedAt = Date(timeIntervalSince1970: 3_000)

        let created = try fixture.store.create(text: "Archive me", now: createdAt)
        try fixture.store.delete(id: created.id, now: deletedAt)

        XCTAssertTrue(try fixture.store.fetchAll().isEmpty)
        let tombstone = try XCTUnwrap(try fixture.store.note(id: created.id))
        XCTAssertEqual(tombstone.deletedAt, deletedAt)
        XCTAssertTrue(tombstone.dirty)
        XCTAssertEqual(try fixture.store.fetchDirty().first?.id, created.id)

        try fixture.store.markClean(ids: [created.id])
        let cleanTombstone = try XCTUnwrap(try fixture.store.note(id: created.id))
        XCTAssertEqual(cleanTombstone.deletedAt, deletedAt)
        XCTAssertFalse(cleanTombstone.dirty)

        let serverText = NoteRecord(
            id: created.id,
            text: "Server won",
            color: NoteColor.blue.rawValue,
            images: ["https://example.com/image.png"],
            type: "text",
            updatedAt: deletedAt.addingTimeInterval(10),
            deletedAt: nil,
            dirty: true
        )
        try fixture.store.applyServerChange(serverText)

        let applied = try XCTUnwrap(try fixture.store.note(id: created.id))
        XCTAssertEqual(applied.text, "Server won")
        XCTAssertEqual(applied.images, ["https://example.com/image.png"])
        XCTAssertNil(applied.deletedAt)
        XCTAssertFalse(applied.dirty)
    }

    func testSyncSnapshotContainsOnlyPortableNoteDataAndRestoresLocalWindowState() throws {
        let source = try makeStore()
        defer { source.cleanup() }
        let destination = try makeStore()
        defer { destination.cleanup() }
        let note = try source.store.create(
            text: "Portable",
            color: NoteColor.green.rawValue,
            images: ["https://oss.example/attachment.png"]
        )
        _ = try destination.store.create(text: "Local", now: Date(timeIntervalSince1970: 1))
        let localCopy = NoteRecord(
            id: note.id,
            text: "Old portable",
            updatedAt: Date(timeIntervalSince1970: 1),
            windowFrame: NoteWindowFrame(x: 20, y: 30, width: 320, height: 240),
            windowLevel: .pinned,
            windowOpacity: 0.4,
            fontSize: 20,
            closed: true
        )
        try destination.store.save(localCopy)

        let snapshotURL = source.directory.appendingPathComponent("sync.sqlite")
        try source.store.makeSyncSnapshot(at: snapshotURL)

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(snapshotURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA table_info(notes)", -1, &statement, nil), SQLITE_OK)
        let columns = try XCTUnwrap(statement)
        defer { sqlite3_finalize(columns) }
        var names: [String] = []
        while sqlite3_step(columns) == SQLITE_ROW {
            names.append(String(cString: sqlite3_column_text(columns, 1)))
        }
        XCTAssertEqual(
            names,
            ["uuid", "text", "color", "images", "type", "updated_at", "deleted_at", "attachments"]
        )

        try destination.store.replaceContent(from: snapshotURL)
        let restored = try XCTUnwrap(try destination.store.note(id: note.id))
        XCTAssertEqual(restored.text, "Portable")
        XCTAssertEqual(restored.images, ["https://oss.example/attachment.png"])
        XCTAssertEqual(restored.windowFrame, localCopy.windowFrame)
        XCTAssertEqual(restored.windowLevel, .pinned)
        XCTAssertEqual(restored.windowOpacity, 0.4, accuracy: 0.001)
        XCTAssertEqual(restored.fontSize, 20)
        XCTAssertTrue(restored.closed)
        XCTAssertFalse(restored.dirty)
        XCTAssertEqual(try destination.store.fetchAll(includeDeleted: true).count, 1)
    }

    func testAttachmentsRoundtripAndTravelInSyncSnapshot() throws {
        let source = try makeStore()
        defer { source.cleanup() }
        let destination = try makeStore()
        defer { destination.cleanup() }

        let image = NoteAttachment(
            url: "https://oss.example/ivy/u1/attachments/photo.jpg",
            thumbnailURL: "https://oss.example/ivy/u1/attachments/thumbnails/photo.thumb.webp",
            name: "photo.jpg",
            sizeBytes: 120_000,
            contentType: "image/jpeg"
        )
        let file = NoteAttachment(
            url: "https://oss.example/ivy/u1/attachments/report.pdf",
            name: "report.pdf",
            sizeBytes: 34_567,
            contentType: "application/pdf"
        )
        let note = try source.store.create(text: "With files", attachments: [image, file])

        let reloaded = try XCTUnwrap(try source.store.note(id: note.id))
        XCTAssertEqual(reloaded.attachments, [image, file])
        XCTAssertTrue(reloaded.attachments[0].isImage)
        XCTAssertFalse(reloaded.attachments[1].isImage)
        XCTAssertEqual(reloaded.attachments[0].displayImageURL, image.thumbnailURL)
        XCTAssertEqual(reloaded.attachments[1].displayImageURL, file.url)

        let removed = try XCTUnwrap(
            try source.store.update(id: note.id, text: reloaded.text, attachments: [image])
        )
        XCTAssertEqual(removed.attachments, [image])
        XCTAssertTrue(removed.dirty)

        let snapshotURL = source.directory.appendingPathComponent("sync.sqlite")
        try source.store.makeSyncSnapshot(at: snapshotURL)
        try destination.store.replaceContent(from: snapshotURL)

        let restored = try XCTUnwrap(try destination.store.note(id: note.id))
        XCTAssertEqual(restored.attachments, [image])
        XCTAssertFalse(restored.dirty)
    }

    func testReplaceContentAcceptsLegacySnapshotWithoutAttachmentsColumn() throws {
        let destination = try makeStore()
        defer { destination.cleanup() }

        let snapshotURL = destination.directory.appendingPathComponent("legacy-sync.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(snapshotURL.path, &handle), SQLITE_OK)
        let legacy = try XCTUnwrap(handle)
        let legacySnapshot = """
        CREATE TABLE notes (
            uuid TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            color TEXT NOT NULL,
            images TEXT NOT NULL,
            type TEXT NOT NULL,
            updated_at REAL NOT NULL,
            deleted_at REAL
        );
        INSERT INTO notes VALUES ('legacy-id', 'Synced from old app', 'blue', '[]', 'text', 1000.0, NULL);
        """
        XCTAssertEqual(sqlite3_exec(legacy, legacySnapshot, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(legacy)

        try destination.store.replaceContent(from: snapshotURL)

        let restored = try XCTUnwrap(try destination.store.note(id: "legacy-id"))
        XCTAssertEqual(restored.text, "Synced from old app")
        XCTAssertTrue(restored.attachments.isEmpty)
        XCTAssertFalse(restored.dirty)
    }

    func testMergeContentUsesPerNoteLastWriterWins() throws {
        let server = try makeStore()
        defer { server.cleanup() }
        let local = try makeStore()
        defer { local.cleanup() }

        // Server rows.
        try server.store.save(NoteRecord(
            id: "shared-local-newer", text: "server stale",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        try server.store.save(NoteRecord(
            id: "shared-server-newer", text: "server v2",
            updatedAt: Date(timeIntervalSince1970: 1_500)
        ))
        try server.store.save(NoteRecord(
            id: "server-only", text: "created elsewhere",
            updatedAt: Date(timeIntervalSince1970: 1_100)
        ))
        try server.store.save(NoteRecord(
            id: "tombstoned", text: "",
            updatedAt: Date(timeIntervalSince1970: 1_200),
            deletedAt: Date(timeIntervalSince1970: 1_200)
        ))

        // Local rows.
        try local.store.save(NoteRecord(
            id: "shared-local-newer", text: "local edit wins",
            updatedAt: Date(timeIntervalSince1970: 2_000), dirty: true
        ))
        try local.store.save(NoteRecord(
            id: "shared-server-newer", text: "local v1",
            updatedAt: Date(timeIntervalSince1970: 1_400), dirty: true
        ))
        try local.store.save(NoteRecord(
            id: "local-only", text: "offline note",
            updatedAt: Date(timeIntervalSince1970: 900), dirty: true
        ))
        try local.store.save(NoteRecord(
            id: "tombstoned", text: "still alive here",
            updatedAt: Date(timeIntervalSince1970: 1_000), dirty: false
        ))

        let snapshotURL = server.directory.appendingPathComponent("snapshot.sqlite")
        try server.store.makeSyncSnapshot(at: snapshotURL)
        try local.store.mergeContent(from: snapshotURL)

        let localNewer = try XCTUnwrap(try local.store.note(id: "shared-local-newer"))
        XCTAssertEqual(localNewer.text, "local edit wins")
        XCTAssertTrue(localNewer.dirty, "Losing rows must stay dirty so the next upload carries them")

        let serverNewer = try XCTUnwrap(try local.store.note(id: "shared-server-newer"))
        XCTAssertEqual(serverNewer.text, "server v2")
        XCTAssertFalse(serverNewer.dirty)

        let serverOnly = try XCTUnwrap(try local.store.note(id: "server-only"))
        XCTAssertEqual(serverOnly.text, "created elsewhere")
        XCTAssertFalse(serverOnly.dirty)

        let localOnly = try XCTUnwrap(try local.store.note(id: "local-only"))
        XCTAssertEqual(localOnly.text, "offline note")
        XCTAssertTrue(localOnly.dirty)

        let tombstoned = try XCTUnwrap(try local.store.note(id: "tombstoned"))
        XCTAssertNotNil(tombstoned.deletedAt, "Newer server tombstones delete local copies")
    }

    func testMergeContentKeepsLocalWindowState() throws {
        let server = try makeStore()
        defer { server.cleanup() }
        let local = try makeStore()
        defer { local.cleanup() }

        try server.store.save(NoteRecord(
            id: "note", text: "server text",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        ))
        try local.store.save(NoteRecord(
            id: "note", text: "old",
            updatedAt: Date(timeIntervalSince1970: 1_000), dirty: false,
            windowFrame: NoteWindowFrame(x: 10, y: 20, width: 300, height: 200),
            windowLevel: .pinned
        ))

        let snapshotURL = server.directory.appendingPathComponent("snapshot.sqlite")
        try server.store.makeSyncSnapshot(at: snapshotURL)
        try local.store.mergeContent(from: snapshotURL)

        let merged = try XCTUnwrap(try local.store.note(id: "note"))
        XCTAssertEqual(merged.text, "server text")
        XCTAssertEqual(merged.windowFrame, NoteWindowFrame(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(merged.windowLevel, .pinned)
    }

    func testHasDirtyNotes() throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        XCTAssertFalse(try fixture.store.hasDirtyNotes())
        let created = try fixture.store.create(text: "Dirty")
        XCTAssertTrue(try fixture.store.hasDirtyNotes())
        try fixture.store.markClean(ids: [created.id])
        XCTAssertFalse(try fixture.store.hasDirtyNotes())
    }

    func testMarkCleanSkipsNotesEditedAfterSnapshot() throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        let untouched = try fixture.store.create(text: "Untouched", now: Date(timeIntervalSince1970: 1_000))
        let edited = try fixture.store.create(text: "Edited", now: Date(timeIntervalSince1970: 1_000))
        let dirtyAtSnapshot = try fixture.store.fetchDirty()
        XCTAssertEqual(dirtyAtSnapshot.count, 2)

        _ = try fixture.store.update(id: edited.id, text: "Edited mid-upload", now: Date(timeIntervalSince1970: 2_000))
        try fixture.store.markClean(upToDateWith: dirtyAtSnapshot)

        XCTAssertFalse(try XCTUnwrap(try fixture.store.note(id: untouched.id)).dirty)
        XCTAssertTrue(
            try XCTUnwrap(try fixture.store.note(id: edited.id)).dirty,
            "A note edited after the snapshot was made must ride the next sync"
        )
    }

    private func makeStore() throws -> (store: NoteStore, directory: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try NoteStore(fileURL: directory.appendingPathComponent("notes.sqlite"))
        return (store, directory, { try? FileManager.default.removeItem(at: directory) })
    }
}
