import AppKit
import Foundation
import SwiftUI
import IvyCore
import LeafiyUICore
import LeafiyUI

@main
struct IvyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        LeafiyLocalization.language = SettingsStore().load().selectedAppLanguage
    }

    var body: some Scene {
        Settings {
            IvySettingsView(model: appDelegate.model)
                .id(appDelegate.model.settings.selectedAppLanguage.rawValue)
        }

        LeafiyMenuBarExtra {
            IvyMenuContent(model: appDelegate.model, notesController: appDelegate.notesController)
        } label: {
            LeafiyMenuBarLabel()
                .id(appDelegate.model.settings.selectedAppLanguage.rawValue)
        }
    }
}

private struct IvyMenuContent: View {
    @ObservedObject var model: IvyModel
    @ObservedObject var notesController: NotesController

    private static let newNoteShortcut = KeyboardShortcutSpec(first: .command, second: .shift, key: "N")!

    private var activeNotes: [NoteRecord] {
        notesController.notes.filter { $0.deletedAt == nil }
    }

    private var hasErrorMessage: Bool {
        model.lastErrorMessage != nil || notesController.errorMessage != nil
    }

    var body: some View {
        LeafiyFamilyMenu(language: model.settings.selectedAppLanguage) {
            LeafiyShortcutMenuButton(
                L("New Note"),
                shortcut: Self.newNoteShortcut,
                action: createNote
            )

            Menu(L("Notes")) {
                if activeNotes.isEmpty {
                    Text(L("No Notes"))
                } else {
                    ForEach(activeNotes) { note in
                        Button {
                            reopen(note)
                        } label: {
                            Label {
                                Text(Self.summary(for: note))
                                    .foregroundStyle(note.closed ? .secondary : .primary)
                            } icon: {
                                IvyIconView(note.closed ? .noteHidden : .note)
                            }
                        }
                    }
                }
            }

            Button(L("Show All Notes")) {
                showAllNotes()
            }

            Toggle(
                model.settings.allNotesCollapsed ? L("Restore All Notes") : L("Collapse All Notes"),
                isOn: Binding(
                    get: { model.settings.allNotesCollapsed },
                    set: setAllNotesCollapsed
                )
            )

            if hasErrorMessage {
                Divider()
                if let message = model.lastErrorMessage {
                    Text(message)
                }
                if let message = notesController.errorMessage, message != model.lastErrorMessage {
                    Text(message)
                }
            }
        }
    }

    private func createNote() {
        model.updateSettings { $0.allNotesCollapsed = false }
        notesController.createNote(color: model.settings.defaultNoteColor)
    }

    private func reopen(_ note: NoteRecord) {
        model.updateSettings { $0.allNotesCollapsed = false }
        notesController.reopenNote(id: note.id)
    }

    private func showAllNotes() {
        model.updateSettings { $0.allNotesCollapsed = false }
        notesController.showAllNotes()
    }

    private func setAllNotesCollapsed(_ isCollapsed: Bool) {
        if isCollapsed {
            notesController.collapseAllNotes()
            model.updateSettings { $0.allNotesCollapsed = true }
        } else {
            model.updateSettings { $0.allNotesCollapsed = false }
            notesController.restoreCollapsedNotes()
        }
    }

    private static func summary(for note: NoteRecord) -> String {
        let firstLine = note.text
            .split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L("(Blank note)") }
        return truncated(trimmed, maxLength: 42)
    }

    private static func truncated(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return "\(text.prefix(maxLength - 1))…"
    }
}

@MainActor
final class AppDelegate: LeafiyAppDelegate {
    let model: IvyModel
    let notesController: NotesController

    override init() {
        let settingsStore = SettingsStore()
        self.notesController = NotesController()
        self.model = IvyModel(settingsStore: settingsStore, noteStore: notesController.noteStore)
        super.init()
        model.replaceSettings(settingsStore.load())
    }

    override func leafiyApplicationDidFinishLaunching(_ notification: Notification) {
        LeafiyLocalization.language = model.settings.selectedAppLanguage
        LeafiyLaunchAtLogin.setEnabled(model.settings.launchAtLogin)
        LeafiyApplicationPresentation.shared.apply(model.settings.applicationIconMode)
        notesController.loadExistingNotes(openPanels: !model.settings.allNotesCollapsed)
        notesController.authTokenProvider = { [weak self] in
            self?.model.accountController.clientAuthToken()
        }
        model.accountController.onDatabaseImported = { [weak self] in
            guard let self else { return }
            self.notesController.loadExistingNotes(openPanels: !self.model.settings.allNotesCollapsed)
        }
        model.accountController.start()
    }
}

@MainActor
final class IvyModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var lastErrorMessage: String?

    private let settingsStore: SettingsStore
    private let noteStore: NoteStore?
    lazy var accountController = AccountSyncController(owner: self, noteStore: noteStore)

    init(settingsStore: SettingsStore = SettingsStore(), noteStore: NoteStore? = nil) {
        self.settingsStore = settingsStore
        self.noteStore = noteStore
        settings = settingsStore.load()
        LeafiyLocalization.language = settings.selectedAppLanguage
    }

    func replaceSettings(_ settings: AppSettings) {
        self.settings = settings.normalized()
        LeafiyLocalization.language = self.settings.selectedAppLanguage
        LeafiyApplicationPresentation.shared.apply(self.settings.applicationIconMode)
    }

    func updateSettings(_ mutation: (inout AppSettings) -> Void) {
        var next = settings
        mutation(&next)
        next = next.normalized()
        settings = next
        LeafiyLocalization.language = next.selectedAppLanguage
        LeafiyApplicationPresentation.shared.apply(next.applicationIconMode)
        do {
            try settingsStore.save(next)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}
