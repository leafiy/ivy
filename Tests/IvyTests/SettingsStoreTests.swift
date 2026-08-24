import Foundation
import XCTest
import IvyCore
@testable import Ivy

final class SettingsStoreTests: XCTestCase {
    func testSavePersistsAndLoadRestoresSettings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: fileURL)
        let settings = AppSettings(
            defaultNoteColor: NoteColor.purple.rawValue,
            namespace: "朋友的周末计划 ✨",
            appLanguage: "en",
            launchAtLogin: true,
            applicationIconMode: .dock,
            allNotesCollapsed: true
        )

        try store.save(settings)

        let data = try Data(contentsOf: fileURL)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["defaultNoteColor"] as? String, NoteColor.purple.rawValue)
        XCTAssertNil(payload["syncServerBaseURL"])
        XCTAssertEqual(payload["namespace"] as? String, "朋友的周末计划 ✨")
        XCTAssertNil(payload["username"])
        XCTAssertEqual(payload["launchAtLogin"] as? Bool, true)
        XCTAssertEqual(payload["applicationIconMode"] as? String, "dock")
        XCTAssertEqual(payload["allNotesCollapsed"] as? Bool, true)

        let loaded = store.load()
        XCTAssertEqual(loaded.defaultNoteColor, NoteColor.purple.rawValue)
        XCTAssertEqual(loaded.namespace, "朋友的周末计划 ✨")
        XCTAssertTrue(loaded.launchAtLogin)
        XCTAssertEqual(loaded.applicationIconMode, .dock)
        XCTAssertTrue(loaded.allNotesCollapsed)
    }

    func testLoadLegacySettingsIgnoresObsoleteServerAndPreservesOtherFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("settings.json")
        try Data(
            """
            {
              "appLanguage" : "en",
              "defaultNoteColor" : "green",
              "launchAtLogin" : true,
              "noteWindowLevel" : "desktop",
              "syncServerBaseURL" : "https://legacy.ivy.example",
              "username" : "legacy-user"
            }
            """.utf8
        ).write(to: fileURL)
        let store = SettingsStore(fileURL: fileURL)

        let loaded = store.load()

        XCTAssertEqual(loaded.appLanguage, "en")
        XCTAssertEqual(loaded.defaultNoteColor, NoteColor.green.rawValue)
        XCTAssertTrue(loaded.launchAtLogin)
        XCTAssertEqual(loaded.noteWindowLevel, .normal)
        XCTAssertEqual(loaded.namespace, "legacy-user")
        XCTAssertEqual(loaded.applicationIconMode, .menuBar)
        XCTAssertFalse(loaded.allNotesCollapsed)
    }
}
