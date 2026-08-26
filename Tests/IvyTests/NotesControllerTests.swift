import AppKit
import XCTest
import IvyCore
import LeafiyUI
@testable import Ivy

final class NotesControllerTests: XCTestCase {
    func testArrangedPanelFrameStartsAtTopRightWithDesktopMargin() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_200, height: 800)

        let frame = NotesController.arrangedPanelFrame(in: visibleFrame, avoiding: [])

        XCTAssertEqual(frame, NSRect(x: 848, y: 508, width: 280, height: 220))
    }

    func testArrangedPanelFrameMovesLeftThenWrapsDown() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let topRight = NSRect(x: 848, y: 508, width: 280, height: 220)
        let topMiddle = NSRect(x: 552, y: 508, width: 280, height: 220)
        let topLeft = NSRect(x: 256, y: 508, width: 280, height: 220)

        let leftFrame = NotesController.arrangedPanelFrame(
            in: visibleFrame,
            avoiding: [topRight]
        )
        let wrappedFrame = NotesController.arrangedPanelFrame(
            in: visibleFrame,
            avoiding: [topRight, topMiddle, topLeft]
        )

        XCTAssertEqual(leftFrame, topMiddle)
        XCTAssertEqual(wrappedFrame, NSRect(x: 848, y: 272, width: 280, height: 220))
    }

    @MainActor
    func testNotePanelUsesStandardAppKitResizeFrame() throws {
        _ = NSApplication.shared
        let fixture = try makeStore()
        defer { fixture.cleanup() }
        let controller = NotesController(store: fixture.store)

        controller.createNote(color: NoteColor.yellow.rawValue)
        let noteID = try XCTUnwrap(controller.notes.first?.id)
        let panel = try XCTUnwrap(
            NSApp.windows.first {
                $0.identifier?.rawValue.hasSuffix(".window.ivy-note-\(noteID)") == true
            } as? LeafiyFloatingPanel
        )
        defer { panel.close() }

        XCTAssertTrue(panel.styleMask.contains(.titled))
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.titleVisibility, .hidden)
        XCTAssertTrue(panel.titlebarAppearsTransparent)
        XCTAssertEqual(panel.titlebarSeparatorStyle, .none)
        XCTAssertTrue(panel.standardWindowButton(.closeButton)?.isHidden == true)
        XCTAssertTrue(panel.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        XCTAssertTrue(panel.standardWindowButton(.zoomButton)?.isHidden == true)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        // The window server's own shadow, reasserted after the resizable
        // style resets the flag.
        XCTAssertTrue(panel.hasShadow)
    }

    @MainActor
    func testBlankDraftIsNotPersistedAndIsDiscardedWhenClosed() throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }
        let controller = NotesController(store: fixture.store)

        controller.createNote(color: NoteColor.green.rawValue, openingPanel: false)
        let draft = try XCTUnwrap(controller.notes.first)

        XCTAssertTrue(try fixture.store.fetchAll().isEmpty)

        controller.updateNoteText(id: draft.id, text: " \n\t")
        XCTAssertTrue(try fixture.store.fetchAll().isEmpty)

        controller.closeNote(id: draft.id)
        XCTAssertTrue(controller.notes.isEmpty)
        XCTAssertTrue(try fixture.store.fetchAll().isEmpty)
    }

    @MainActor
    func testDraftIsPersistedAfterReceivingContent() throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }
        let controller = NotesController(store: fixture.store)

        controller.createNote(color: NoteColor.blue.rawValue, openingPanel: false)
        let draft = try XCTUnwrap(controller.notes.first)
        controller.updateNoteText(id: draft.id, text: "Ship it")

        let saved = try XCTUnwrap(try fixture.store.note(id: draft.id))
        XCTAssertEqual(saved.text, "Ship it")
        XCTAssertEqual(saved.color, NoteColor.blue.rawValue)
        XCTAssertTrue(saved.dirty)
    }

    private func makeStore() throws -> (store: NoteStore, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try NoteStore(fileURL: directory.appendingPathComponent("notes.sqlite"))
        return (store, { try? FileManager.default.removeItem(at: directory) })
    }
}
