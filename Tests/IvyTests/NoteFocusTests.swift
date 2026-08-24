import AppKit
import SwiftUI
import XCTest
import IvyCore
import LeafiyUI
@testable import Ivy

@MainActor
final class NoteFocusTests: XCTestCase {
    func testStandardResizeEdgeDoesNotDisturbEditorFocus() throws {
        _ = NSApplication.shared

        let noteView = NoteView(
            note: NoteRecord(text: "Focus me"),
            uploadingFiles: [],
            onTextChange: { _, _ in },
            onColorChange: { _, _ in },
            onTogglePin: { _ in },
            onOpacityChange: { _, _ in },
            onFontSizeChange: { _, _ in },
            onClose: { _ in },
            onDelete: { _ in },
            onAddAttachments: { _, _ in },
            onDeleteAttachment: { _, _ in },
            onDownloadAttachment: { _ in }
        )
        let panel = LeafiyFloatingPanel(
            configuration: .init(
                canBecomeKey: true,
                styleMask: [.titled, .resizable, .fullSizeContentView],
                identifier: "test-note-resize"
            ),
            content: noteView
        )
        panel.setFrame(
            NSRect(x: 0, y: 0, width: 280, height: 220),
            display: false
        )
        panel.minSize = NSSize(width: 220, height: 160)
        panel.contentMinSize = panel.minSize
        panel.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        defer { panel.close() }
        let hostingView = try XCTUnwrap(panel.contentView)

        let editor = try XCTUnwrap(findSubview(of: NoteRichTextView.self, in: hostingView))
        let dragView = try XCTUnwrap(
            allSubviews(in: hostingView).first {
                String(describing: type(of: $0)).contains("NoteWindowDragView")
            }
        )

        let backgroundPoint = dragView.convert(
            NSPoint(x: 14, y: dragView.bounds.midY),
            to: nil
        )
        sendMouseClick(at: backgroundPoint, in: panel, eventNumber: 1)
        XCTAssertTrue(
            panel.firstResponder === editor,
            "A mouse-down away from the resize frame should focus the editor immediately."
        )

        let resizePoint = dragView.convert(
            NSPoint(x: 4, y: dragView.bounds.midY),
            to: nil
        )
        sendMouseClick(at: resizePoint, in: panel, eventNumber: 3)
        XCTAssertTrue(
            panel.firstResponder === editor,
            "Starting a standard resize must preserve the current editor responder."
        )

        XCTAssertTrue(panel.makeFirstResponder(nil))
        sendMouseClick(at: resizePoint, in: panel, eventNumber: 5)
        XCTAssertFalse(
            panel.firstResponder === editor,
            "A standard resize-frame mouse-down must not force editor focus."
        )
    }

    func testCommandPlusAndMinusResizeOnlyTheCurrentNoteEditor() throws {
        _ = NSApplication.shared
        var changedSizes: [Double] = []
        let noteView = NoteView(
            note: NoteRecord(text: "Zoom me"),
            uploadingFiles: [],
            onTextChange: { _, _ in },
            onColorChange: { _, _ in },
            onTogglePin: { _ in },
            onOpacityChange: { _, _ in },
            onFontSizeChange: { _, size in changedSizes.append(size) },
            onClose: { _ in },
            onDelete: { _ in },
            onAddAttachments: { _, _ in },
            onDeleteAttachment: { _, _ in },
            onDownloadAttachment: { _ in }
        )
        let hostingView = NSHostingView(rootView: noteView)
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.makeKeyAndOrderFront(nil)
        panel.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        defer { panel.close() }

        let editor = try XCTUnwrap(findSubview(of: NoteRichTextView.self, in: hostingView))
        XCTAssertEqual(editor.renderedFontSize, CGFloat(NoteRecord.defaultFontSize))

        NSApp.sendEvent(keyEvent(
            characters: "+",
            charactersIgnoringModifiers: "=",
            modifiers: [.command, .shift],
            keyCode: 24,
            windowNumber: panel.windowNumber
        ))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(changedSizes, [15])
        XCTAssertEqual(editor.renderedFontSize, 15)
        XCTAssertEqual(editor.string, "Zoom me")

        NSApp.sendEvent(keyEvent(
            characters: "-",
            charactersIgnoringModifiers: "-",
            modifiers: [.command],
            keyCode: 27,
            windowNumber: panel.windowNumber
        ))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(changedSizes, [15, 14])
        XCTAssertEqual(editor.renderedFontSize, 14)
        XCTAssertEqual(editor.string, "Zoom me")
    }


    private func sendMouseClick(at point: NSPoint, in panel: NSPanel, eventNumber: Int) {
        guard
            let mouseDown = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: 1,
                pressure: 1
            ),
            let mouseUp = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: eventNumber + 1,
                clickCount: 1,
                pressure: 0
            )
        else {
            XCTFail("Could not create mouse events")
            return
        }

        NSApp.postEvent(mouseUp, atStart: false)
        NSApp.sendEvent(mouseDown)
    }

    private func keyEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func findSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = findSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    private func allSubviews(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + allSubviews(in: $0) }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
