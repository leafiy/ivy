import AppKit
import Foundation
import SwiftUI
import IvyCore
import LeafiyUI

private enum NotePanelLayout {
    static let defaultSize = NSSize(width: 280, height: 220)
    static let minimumSize = NSSize(width: 220, height: 160)
    static let newPanelScreenMargin: CGFloat = 72
    static let arrangedPanelSpacing: CGFloat = 16
}

@MainActor
final class NotesController: ObservableObject {
    private enum PanelPlacement {
        case restored
        case newlyCreated
    }

    @Published private(set) var notes: [NoteRecord] = []
    @Published private(set) var errorMessage: String?
    /// Per-note minimal upload state, mirrored into the note's file list.
    @Published private(set) var uploadStatuses: [String: [NoteUploadStatusItem]] = [:]

    /// Returns the signed-in sync token; attachments cannot upload without one.
    /// Injected by the app delegate once the account controller exists.
    var authTokenProvider: (@MainActor () -> String?)?

    private let store: NoteStore?
    var noteStore: NoteStore? { store }
    private let syncClient = SyncClient()
    private var panels: [String: LeafiyFloatingPanel] = [:]
    private var frameObservers: [String: [NSObjectProtocol]] = [:]
    private var frameWriteWorkItems: [String: DispatchWorkItem] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]
    private var unsavedNoteIDs: Set<String> = []

    /// One file dropped or pasted onto a note, waiting its turn in the
    /// background upload queue.
    private struct QueuedNoteUpload {
        let id: String
        let noteID: String
        let file: PendingNoteAttachment
    }

    private var uploadQueue: [QueuedNoteUpload] = []
    private var isProcessingUploadQueue = false

    init() {
        do {
            store = try NoteStore()
        } catch {
            store = nil
            errorMessage = error.localizedDescription
        }
    }

    init(store: NoteStore) {
        self.store = store
    }

    func loadExistingNotes(openPanels: Bool = true) {
        guard let store else { return }
        do {
            let loadedNotes = try store.fetchAll()
            notes = loadedNotes
            if openPanels {
                for note in loadedNotes where note.deletedAt == nil && !note.closed {
                    openPanel(for: note)
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createNote(color: String, openingPanel: Bool = true) {
        guard store != nil else {
            presentError(errorMessage ?? L("Notes database is unavailable."))
            return
        }

        let note = NoteRecord(
            text: "",
            color: NoteColor.allowedRawValues.contains(color) ? color : NoteColor.white.rawValue
        )
        unsavedNoteIDs.insert(note.id)
        notes.insert(note, at: 0)
        if openingPanel {
            openPanel(for: note, placement: .newlyCreated)
        }
        errorMessage = nil
    }

    func showAllNotes() {
        guard let store else { return }
        if notes.isEmpty {
            loadExistingNotes(openPanels: false)
        }
        let visibleNotes = notes.filter { $0.deletedAt == nil }
        do {
            for note in visibleNotes {
                let noteToOpen: NoteRecord
                if note.closed {
                    guard let updated = try store.updateWindowState(id: note.id, closed: false) else { continue }
                    replaceCachedNote(updated)
                    noteToOpen = updated
                } else {
                    noteToOpen = note
                }
                openPanel(for: noteToOpen)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func collapseAllNotes() {
        for panel in panels.values where panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func restoreCollapsedNotes() {
        if notes.isEmpty {
            loadExistingNotes(openPanels: false)
        }
        for note in notes where note.deletedAt == nil && !note.closed {
            openPanel(for: note)
        }
    }

    private func makeNoteView(for note: NoteRecord) -> NoteView {
        NoteView(
            note: note,
            uploadingFiles: uploadStatuses[note.id] ?? [],
            onTextChange: { [weak self] id, text in
                self?.updateNoteText(id: id, text: text)
            },
            onColorChange: { [weak self] id, color in
                self?.updateNoteColor(id: id, color: color)
            },
            onTogglePin: { [weak self] id in
                self?.togglePin(id: id)
            },
            onOpacityChange: { [weak self] id, opacity in
                self?.updateNoteOpacity(id: id, opacity: opacity)
            },
            onFontSizeChange: { [weak self] id, fontSize in
                self?.updateNoteFontSize(id: id, fontSize: fontSize)
            },
            onClose: { [weak self] id in
                self?.closeNote(id: id)
            },
            onDelete: { [weak self] id in
                self?.deleteNote(id: id)
            },
            onAddAttachments: { [weak self] id, pending in
                self?.addAttachments(noteID: id, pending: pending)
            },
            onDeleteAttachment: { [weak self] id, attachment in
                self?.deleteAttachment(noteID: id, attachment: attachment)
            },
            onDownloadAttachment: { [weak self] attachment in
                self?.downloadAttachment(attachment)
            }
        )
    }

    private func openPanel(for note: NoteRecord, placement: PanelPlacement = .restored) {
        let content = makeNoteView(for: note)

        if let panel = panels[note.id] {
            configurePanel(panel)
            panel.level = Self.panelLevel(for: note.windowLevel)
            panel.setContent(content)
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }

        let configuration = LeafiyFloatingPanelConfiguration(
            level: Self.panelLevel(for: note.windowLevel),
            canBecomeKey: true,
            isMovable: true,
            hasShadow: false,
            styleMask: [.titled, .resizable, .fullSizeContentView],
            identifier: "ivy-note-\(note.id)",
            title: L("Ivy Note")
        )
        let panel = LeafiyFloatingPanel(configuration: configuration, content: content)
        configurePanel(panel)
        panel.setFrame(initialFrame(for: note, index: panels.count, placement: placement), display: false)
        panels[note.id] = panel
        observeFrameChanges(of: panel, noteID: note.id)
        observeClose(of: panel, noteID: note.id)
        if note.windowFrame == nil {
            persistFrame(of: panel, noteID: note.id)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func configurePanel(_ panel: LeafiyFloatingPanel) {
        // Keep standard AppKit window framing and resize tracking. Only the
        // titlebar's appearance is suppressed; AppKit still owns hit testing,
        // cursors, live resize, movement, and focus transitions.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.hasShadow = false
        panel.minSize = NotePanelLayout.minimumSize
        panel.contentMinSize = NotePanelLayout.minimumSize
    }

    /// Stored frame wins. A newly-created note uses the top-right arrangement;
    /// the legacy cascade remains only for older never-placed records.
    private func initialFrame(for note: NoteRecord, index: Int, placement: PanelPlacement) -> NSRect {
        guard let storedFrame = note.windowFrame else {
            if placement == .newlyCreated, let screen = Self.screenContainingPointer() ?? NSScreen.main {
                return Self.arrangedPanelFrame(
                    in: screen.visibleFrame,
                    avoiding: visiblePinnedFrames(on: screen)
                )
            }
            return Self.nextPanelFrame(index: index)
        }

        let restoredFrame = NSRect(
            x: CGFloat(storedFrame.x),
            y: CGFloat(storedFrame.y),
            width: CGFloat(storedFrame.width),
            height: CGFloat(storedFrame.height)
        )
        return Self.clampedFrame(restoredFrame)
    }

    private func visiblePinnedFrames(on screen: NSScreen) -> [NSRect] {
        panels.compactMap { noteID, panel in
            guard
                panel.isVisible,
                panel.frame.intersects(screen.visibleFrame),
                notes.first(where: { $0.id == noteID })?.windowLevel == .pinned
            else { return nil }
            return panel.frame
        }
    }

    private static func screenContainingPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) }
    }

    /// Produces top-right slots, moving left first and wrapping downward.
    /// Only visible pinned frames block a slot, so manual placement is preserved.
    nonisolated static func arrangedPanelFrame(in visibleFrame: NSRect, avoiding occupiedFrames: [NSRect]) -> NSRect {
        let size = NotePanelLayout.defaultSize
        let rightmostX = visibleFrame.maxX - NotePanelLayout.newPanelScreenMargin - size.width
        let leftmostX = visibleFrame.minX + NotePanelLayout.newPanelScreenMargin
        let topmostY = visibleFrame.maxY - NotePanelLayout.newPanelScreenMargin - size.height
        let bottommostY = visibleFrame.minY + NotePanelLayout.newPanelScreenMargin
        let obstructions = occupiedFrames.map {
            $0.insetBy(
                dx: -NotePanelLayout.arrangedPanelSpacing,
                dy: -NotePanelLayout.arrangedPanelSpacing
            )
        }

        var y = topmostY
        while y >= bottommostY {
            var x = rightmostX
            while x >= leftmostX {
                let candidate = NSRect(origin: NSPoint(x: x, y: y), size: size)
                if !obstructions.contains(where: { $0.intersects(candidate) }) {
                    return candidate
                }
                x -= size.width + NotePanelLayout.arrangedPanelSpacing
            }
            y -= size.height + NotePanelLayout.arrangedPanelSpacing
        }

        return NSRect(origin: NSPoint(x: rightmostX, y: topmostY), size: size)
    }

    /// Persists moves/resizes, debounced per note; never marks the note dirty.
    private func observeFrameChanges(of panel: LeafiyFloatingPanel, noteID: String) {
        let center = NotificationCenter.default
        frameObservers.removeValue(forKey: noteID)?.forEach { center.removeObserver($0) }
        frameWriteWorkItems.removeValue(forKey: noteID)?.cancel()

        let persistFrame: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panels[noteID] else { return }
                self.scheduleFrameWrite(for: panel, noteID: noteID)
            }
        }

        frameObservers[noteID] = [
            center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main,
                using: persistFrame
            ),
            center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: panel,
                queue: .main,
                using: persistFrame
            )
        ]
    }

    private func scheduleFrameWrite(for panel: LeafiyFloatingPanel, noteID: String) {
        frameWriteWorkItems.removeValue(forKey: noteID)?.cancel()

        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard
                    let self,
                    let panel,
                    let workItem,
                    let currentWorkItem = self.frameWriteWorkItems[noteID],
                    currentWorkItem === workItem
                else { return }
                self.frameWriteWorkItems[noteID] = nil
                self.persistFrame(of: panel, noteID: noteID)
            }
        }

        guard let workItem else { return }
        frameWriteWorkItems[noteID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400), execute: workItem)
    }

    private func persistFrame(of panel: LeafiyFloatingPanel, noteID: String) {
        guard let store else { return }

        let frame = panel.frame
        let windowFrame = NoteWindowFrame(
            x: Double(frame.origin.x),
            y: Double(frame.origin.y),
            width: Double(frame.size.width),
            height: Double(frame.size.height)
        )

        if unsavedNoteIDs.contains(noteID), var draft = notes.first(where: { $0.id == noteID }) {
            draft.windowFrame = windowFrame
            replaceCachedNote(draft)
            return
        }

        do {
            guard let updated = try store.updateWindowState(id: noteID, frame: windowFrame) else { return }
            replaceCachedNote(updated)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Esc and the window close button must land in the same `closed` state as `closeNote`.
    private func observeClose(of panel: LeafiyFloatingPanel, noteID: String) {
        if let observer = closeObservers.removeValue(forKey: noteID) {
            NotificationCenter.default.removeObserver(observer)
        }
        closeObservers[noteID] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.markNoteClosed(id: noteID)
            }
        }
    }

    /// Hides without releasing; the panel stays cached for reopening.
    func closeNote(id: String) {
        if discardUnsavedBlankNote(id: id) { return }
        panels[id]?.orderOut(nil)
        markNoteClosed(id: id)
    }

    /// Menu entry point (ticket 07): make a hidden note visible again.
    func reopenNote(id: String) {
        guard let store else { return }
        do {
            guard let updated = try store.updateWindowState(id: id, closed: false) else { return }
            replaceCachedNote(updated)
            openPanel(for: updated)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Flips this note between desktop-pinned and floating, without syncing.
    func togglePin(id: String) {
        guard let store else { return }

        do {
            if unsavedNoteIDs.contains(id), var draft = notes.first(where: { $0.id == id }) {
                draft.windowLevel = draft.windowLevel == .pinned ? .normal : .pinned
                replaceCachedNote(draft)
                openPanel(for: draft)
                errorMessage = nil
                return
            }

            let current: NoteRecord
            if let cached = notes.first(where: { $0.id == id }) {
                current = cached
            } else {
                guard let stored = try store.note(id: id) else { return }
                current = stored
            }
            let nextLevel: NoteWindowLevel = current.windowLevel == .pinned ? .normal : .pinned
            guard let updated = try store.updateWindowState(id: id, level: nextLevel) else { return }
            replaceCachedNote(updated)
            openPanel(for: updated)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateNoteColor(id: String, color: String) {
        guard let store else { return }
        do {
            if unsavedNoteIDs.contains(id), var draft = notes.first(where: { $0.id == id }) {
                draft.color = NoteColor.allowedRawValues.contains(color) ? color : NoteColor.white.rawValue
                replaceCachedNote(draft)
                openPanel(for: draft)
                errorMessage = nil
                return
            }

            guard let current = try store.note(id: id) else { return }
            guard let updated = try store.update(id: id, text: current.text, color: color) else { return }
            replaceCachedNote(updated)
            openPanel(for: updated)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateNoteOpacity(id: String, opacity: Double) {
        guard let store else { return }
        let normalizedOpacity = min(max(opacity, 0.1), 1)
        do {
            if unsavedNoteIDs.contains(id), var draft = notes.first(where: { $0.id == id }) {
                draft.windowOpacity = normalizedOpacity
                replaceCachedNote(draft)
                errorMessage = nil
                return
            }

            guard let updated = try store.updateWindowState(id: id, opacity: normalizedOpacity) else { return }
            replaceCachedNote(updated)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateNoteFontSize(id: String, fontSize: Double) {
        guard let store else { return }
        let normalizedFontSize = min(
            max(fontSize, NoteRecord.minimumFontSize),
            NoteRecord.maximumFontSize
        )
        do {
            if unsavedNoteIDs.contains(id), var draft = notes.first(where: { $0.id == id }) {
                draft.fontSize = normalizedFontSize
                replaceCachedNote(draft)
                errorMessage = nil
                return
            }

            guard let updated = try store.updateWindowState(id: id, fontSize: normalizedFontSize) else {
                return
            }
            replaceCachedNote(updated)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateNoteText(id: String, text: String) {
        guard let store else { return }
        do {
            if unsavedNoteIDs.contains(id), var draft = notes.first(where: { $0.id == id }) {
                draft.text = text
                replaceCachedNote(draft)

                guard !Self.isBlank(draft) else {
                    errorMessage = nil
                    return
                }

                draft.updatedAt = Date()
                draft.dirty = true
                try store.save(draft)
                unsavedNoteIDs.remove(id)
                replaceCachedNote(draft)
                errorMessage = nil
                return
            }

            guard let updated = try store.update(id: id, text: text) else { return }
            replaceCachedNote(updated)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Attachments

    /// Accepts dropped/pasted files: verifies count, total size, and the
    /// account's remaining attachment quota up front, then feeds everything
    /// into the background upload queue. Nothing blocks the user afterwards;
    /// per-file progress is limited to a spinner row in the file list, and
    /// images already sit inline as pending markers.
    func addAttachments(noteID: String, pending: [PendingNoteAttachment]) {
        guard store != nil, !pending.isEmpty else { return }
        guard pending.count <= 50 else {
            discardPendingMarkers(noteID: noteID, for: pending)
            presentAttachmentError(L("Attach at most 50 files at a time."))
            return
        }
        guard let token = authTokenProvider?() else {
            discardPendingMarkers(noteID: noteID, for: pending)
            presentAttachmentError(L("Sign in in Settings before adding attachments."))
            return
        }

        let newBytes = pending.reduce(Int64(0)) { $0 + Int64($1.data.count) }
        let queuedBytes = uploadQueue.reduce(Int64(0)) { $0 + Int64($1.file.data.count) }

        Task {
            do {
                let quota = try await syncClient.attachmentQuota(token: token)
                guard newBytes + queuedBytes <= quota.remainingBytes else {
                    discardPendingMarkers(noteID: noteID, for: pending)
                    presentAttachmentError(String(
                        format: L("Not enough attachment space. %@ remaining."),
                        NoteAttachmentFormat.sizeText(max(quota.remainingBytes - queuedBytes, 0))
                    ))
                    return
                }
                enqueueUploads(noteID: noteID, pending: pending)
                processUploadQueue()
                errorMessage = nil
            } catch {
                discardPendingMarkers(noteID: noteID, for: pending)
                errorMessage = error.localizedDescription
                presentAttachmentError(error.localizedDescription)
            }
        }
    }

    private func enqueueUploads(noteID: String, pending: [PendingNoteAttachment]) {
        for file in pending {
            let item = QueuedNoteUpload(id: UUID().uuidString, noteID: noteID, file: file)
            uploadQueue.append(item)
            uploadStatuses[noteID, default: []].append(
                NoteUploadStatusItem(id: item.id, name: file.filename, isImage: file.isImage)
            )
        }
        refreshPanelContent(noteID: noteID)
    }

    /// Drains the queue one file per request (the API accepts at most ten per
    /// call); finishing one file at a time keeps the note text, attachment
    /// metadata, and status rows moving in step. A failed file cancels the
    /// remaining queue for its note so one broken network state cannot raise
    /// fifty alerts.
    private func processUploadQueue() {
        guard !isProcessingUploadQueue, !uploadQueue.isEmpty else { return }
        isProcessingUploadQueue = true
        Task {
            defer { isProcessingUploadQueue = false }
            while let item = uploadQueue.first {
                let succeeded = await uploadQueuedItem(item)
                uploadQueue.removeFirst()
                finishUploadStatus(for: item)
                if !succeeded {
                    let cancelled = uploadQueue.filter { $0.noteID == item.noteID }
                    uploadQueue.removeAll { $0.noteID == item.noteID }
                    for cancelledItem in cancelled {
                        discardPendingMarker(
                            noteID: cancelledItem.noteID,
                            markerID: cancelledItem.file.inlineMarkerID
                        )
                        finishUploadStatus(for: cancelledItem)
                    }
                }
            }
        }
    }

    private func uploadQueuedItem(_ item: QueuedNoteUpload) async -> Bool {
        guard let token = authTokenProvider?() else {
            discardPendingMarker(noteID: item.noteID, markerID: item.file.inlineMarkerID)
            return false
        }
        do {
            let response = try await syncClient.uploadAttachments(
                token: token,
                files: [item.file.uploadFile]
            )
            let uploaded = Self.uploadedAttachments(response: response, pending: [item.file])
            guard let attachment = uploaded.first else { return true }
            if let markerID = item.file.inlineMarkerID {
                // Alias the local bytes to the final URL so the inline image
                // never flashes or refetches, then swap the marker in place.
                NoteInlineImageStore.shared.registerLocal(data: item.file.data, for: attachment.url)
                replacePendingMarker(noteID: item.noteID, markerID: markerID, with: attachment.url)
            }
            try applyAttachmentChange(noteID: item.noteID) { $0 + [attachment] }
            errorMessage = nil
            return true
        } catch {
            discardPendingMarker(noteID: item.noteID, markerID: item.file.inlineMarkerID)
            errorMessage = error.localizedDescription
            presentAttachmentError(error.localizedDescription)
            return false
        }
    }

    private func finishUploadStatus(for item: QueuedNoteUpload) {
        uploadStatuses[item.noteID]?.removeAll { $0.id == item.id }
        if uploadStatuses[item.noteID]?.isEmpty == true {
            uploadStatuses.removeValue(forKey: item.noteID)
        }
        refreshPanelContent(noteID: item.noteID)
    }

    private func replacePendingMarker(noteID: String, markerID: String, with url: String) {
        guard let currentText = currentNoteText(noteID) else { return }
        let newText = NoteInlineImage.replacingPendingURL(id: markerID, with: url, in: currentText)
        guard newText != currentText else { return }
        updateNoteText(id: noteID, text: newText)
    }

    /// Removes a rejected or failed upload's inline placeholder from the
    /// note text and rebuilds the panel so the editor drops the dead cell.
    private func discardPendingMarker(noteID: String, markerID: String?) {
        guard let markerID, let currentText = currentNoteText(noteID) else { return }
        let newText = NoteInlineImage.removingPendingMarker(id: markerID, from: currentText)
        guard newText != currentText else { return }
        updateNoteText(id: noteID, text: newText)
        refreshPanelContent(noteID: noteID)
    }

    private func discardPendingMarkers(noteID: String, for pending: [PendingNoteAttachment]) {
        for file in pending {
            discardPendingMarker(noteID: noteID, markerID: file.inlineMarkerID)
        }
    }

    private func currentNoteText(_ noteID: String) -> String? {
        if let cached = notes.first(where: { $0.id == noteID }) { return cached.text }
        return try? store?.note(id: noteID)?.text
    }

    /// Removes the attachment from the note immediately, then frees its
    /// server-side quota. A missing server record (deleted from another
    /// device) is not an error.
    func deleteAttachment(noteID: String, attachment: NoteAttachment) {
        do {
            try applyAttachmentChange(noteID: noteID) { attachments in
                attachments.filter { $0.url != attachment.url }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard let token = authTokenProvider?() else { return }
        Task {
            do {
                try await syncClient.deleteAttachment(token: token, url: attachment.url)
            } catch SyncClientError.server(let statusCode, _) where statusCode == 404 {
                // Already gone server-side; nothing to free.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func downloadAttachment(_ attachment: NoteAttachment) {
        guard let remoteURL = URL(string: attachment.url) else { return }

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = attachment.name
        savePanel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard savePanel.runModal() == .OK, let destination = savePanel.url else { return }

        Task {
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: remoteURL)
                guard
                    let httpResponse = response as? HTTPURLResponse,
                    (200..<300).contains(httpResponse.statusCode)
                else {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    throw SyncClientError.server(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: Data())
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                presentAttachmentError(error.localizedDescription)
            }
        }
    }

    /// Persists an attachment-list change as a content edit (dirty + synced).
    /// A never-saved draft note becomes real on its first attachment.
    private func applyAttachmentChange(
        noteID: String,
        _ transform: ([NoteAttachment]) -> [NoteAttachment]
    ) throws {
        guard let store else { return }

        if unsavedNoteIDs.contains(noteID), var draft = notes.first(where: { $0.id == noteID }) {
            draft.attachments = transform(draft.attachments)
            draft.updatedAt = Date()
            draft.dirty = true
            try store.save(draft)
            unsavedNoteIDs.remove(noteID)
            replaceCachedNote(draft)
            refreshPanelContent(noteID: noteID)
            return
        }

        guard let current = try store.note(id: noteID) else { return }
        guard let updated = try store.update(
            id: noteID,
            text: current.text,
            attachments: transform(current.attachments)
        ) else { return }
        replaceCachedNote(updated)
        refreshPanelContent(noteID: noteID)
    }

    /// Server metadata is authoritative; when talking to an older API that
    /// returns bare URLs, rebuild the metadata from what we sent.
    private static func uploadedAttachments(
        response: AttachmentUploadResponse,
        pending: [PendingNoteAttachment]
    ) -> [NoteAttachment] {
        guard response.attachments.isEmpty else { return response.attachments }
        return zip(response.urls, pending).map { url, item in
            NoteAttachment(
                url: url.absoluteString,
                name: item.filename,
                sizeBytes: Int64(item.data.count),
                contentType: item.contentType
            )
        }
    }

    /// Swaps the panel's SwiftUI content in place without reordering windows
    /// or stealing key status (unlike openPanel).
    private func refreshPanelContent(noteID: String) {
        guard
            let panel = panels[noteID],
            let note = notes.first(where: { $0.id == noteID })
        else { return }
        panel.setContent(makeNoteView(for: note))
    }

    private func presentAttachmentError(_ message: String) {
        presentAlert(title: L("Ivy could not attach the file."), message: message)
    }

    private func deleteNote(id: String) {
        guard let store else { return }
        if discardUnsavedBlankNote(id: id) { return }
        guard confirmDeleteNote() else { return }
        do {
            try store.delete(id: id)
            notes.removeAll { $0.id == id }
            frameWriteWorkItems.removeValue(forKey: id)?.cancel()
            frameObservers.removeValue(forKey: id)?.forEach { NotificationCenter.default.removeObserver($0) }
            if let observer = closeObservers.removeValue(forKey: id) {
                NotificationCenter.default.removeObserver(observer)
            }
            panels.removeValue(forKey: id)?.close()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func markNoteClosed(id: String) {
        guard let store else { return }
        if discardUnsavedBlankNote(id: id, hidePanel: false) { return }
        do {
            guard let updated = try store.updateWindowState(id: id, closed: true) else { return }
            replaceCachedNote(updated)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirmDeleteNote() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Delete this note?")
        alert.informativeText = L("Deleting syncs to every device and cannot be undone.")
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentError(_ message: String) {
        presentAlert(title: L("Ivy could not create a note."), message: message)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func replaceCachedNote(_ note: NoteRecord) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.insert(note, at: 0)
        }
    }

    private func discardUnsavedBlankNote(id: String, hidePanel: Bool = true) -> Bool {
        guard
            unsavedNoteIDs.contains(id),
            let note = notes.first(where: { $0.id == id }),
            Self.isBlank(note)
        else { return false }

        unsavedNoteIDs.remove(id)
        notes.removeAll { $0.id == id }
        frameWriteWorkItems.removeValue(forKey: id)?.cancel()
        frameObservers.removeValue(forKey: id)?.forEach { NotificationCenter.default.removeObserver($0) }
        if let observer = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        if let panel = panels.removeValue(forKey: id), hidePanel {
            panel.orderOut(nil)
        }
        errorMessage = nil
        return true
    }

    private static func isBlank(_ note: NoteRecord) -> Bool {
        note.images.isEmpty
            && note.attachments.isEmpty
            && note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func clampedFrame(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = screens.first { $0.frame.contains(center) }
            ?? screens.min { lhs, rhs in
                distanceSquared(from: center, to: lhs.frame) < distanceSquared(from: center, to: rhs.frame)
            }
            ?? NSScreen.main

        guard let screen else { return frame }

        let visibleFrame = screen.visibleFrame
        let margin: CGFloat = 12
        let maxWidth = max(visibleFrame.width - margin * 2, 1)
        let maxHeight = max(visibleFrame.height - margin * 2, 1)
        var clampedFrame = frame
        clampedFrame.size.width = min(max(clampedFrame.width, 1), maxWidth)
        clampedFrame.size.height = min(max(clampedFrame.height, 1), maxHeight)

        clampedFrame.origin.x = clamped(
            clampedFrame.origin.x,
            minimum: visibleFrame.minX + margin,
            maximum: visibleFrame.maxX - margin - clampedFrame.width
        )
        clampedFrame.origin.y = clamped(
            clampedFrame.origin.y,
            minimum: visibleFrame.minY + margin,
            maximum: visibleFrame.maxY - margin - clampedFrame.height
        )
        return clampedFrame
    }

    private static func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard minimum <= maximum else {
            return (minimum + maximum) / 2
        }
        return min(max(value, minimum), maximum)
    }

    private static func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }

        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }

        return dx * dx + dy * dy
    }

    private static func panelLevel(for windowLevel: NoteWindowLevel) -> NSWindow.Level {
        switch windowLevel {
        case .normal:
            return .normal
        case .pinned:
            return .floating
        }
    }


    private static func nextPanelFrame(index: Int) -> NSRect {
        let offset = CGFloat((index % 8) * 28)
        return NSRect(
            x: 96 + offset,
            y: 360 - offset,
            width: NotePanelLayout.defaultSize.width,
            height: NotePanelLayout.defaultSize.height
        )
    }
}
