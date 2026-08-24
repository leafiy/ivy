import Foundation
import IvyCore
import LeafiyUICore

final class SettingsStore {
    private let store: LeafiySettingsStore<AppSettings>

    init(fileURL: URL? = nil) {
        self.store = fileURL.map { LeafiySettingsStore(fileURL: $0) }
            ?? .standard(directoryName: "Ivy")
    }

    var hasSavedSettings: Bool {
        store.hasSavedSettings
    }

    func load() -> AppSettings {
        store.load()
    }

    func save(_ settings: AppSettings) throws {
        try store.save(settings)
    }
}
