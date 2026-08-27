import Foundation
import LeafiyUICore

public enum NoteWindowLevel: String, Codable, CaseIterable, Equatable, Sendable {
    case normal
    case pinned

    public static func value(for rawValue: String) -> NoteWindowLevel {
        if rawValue == "desktop" { return .normal }
        return NoteWindowLevel(rawValue: rawValue) ?? .normal
    }
}

public enum NoteColor: String, Codable, CaseIterable, Equatable, Sendable {
    case white
    case pink
    case gray
    case yellow
    case green
    case blue
    case purple

    public static let allowedRawValues = Set(allCases.map(\.rawValue))
}

/// The signed-in sync session. A Secret, therefore an ordinary Settings
/// field stored in plaintext settings.json (ADR-0002).
public struct SyncSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct AppSettings: Codable, Equatable, LeafiyAppSettings {
    public var noteWindowLevel: NoteWindowLevel
    public var defaultNoteColor: String
    public var namespace: String
    public var syncDeviceID: String
    public var syncDatabaseVersion: Int
    public var syncDatabaseDirty: Bool
    public var appLanguage: String
    public var launchAtLogin: Bool
    public var applicationIconMode: LeafiyApplicationIconMode

    public var allNotesCollapsed: Bool
    public var syncSession: SyncSession?

    private enum CodingKeys: String, CodingKey {
        case noteWindowLevel
        case defaultNoteColor
        case namespace
        case username
        case syncDeviceID
        case syncDatabaseVersion
        case syncDatabaseDirty
        case appLanguage
        case launchAtLogin
        case applicationIconMode
        case allNotesCollapsed
        case syncSession
    }
    public init(
        noteWindowLevel: NoteWindowLevel = .normal,
        defaultNoteColor: String = NoteColor.white.rawValue,
        namespace: String = "",
        syncDeviceID: String = UUID().uuidString.lowercased(),
        syncDatabaseVersion: Int = 0,
        syncDatabaseDirty: Bool = false,
        appLanguage: String = AppLanguage.system.rawValue,
        launchAtLogin: Bool = false,
        applicationIconMode: LeafiyApplicationIconMode = .menuBar,
        allNotesCollapsed: Bool = false,
        syncSession: SyncSession? = nil
    ) {
        self.noteWindowLevel = noteWindowLevel
        self.defaultNoteColor = defaultNoteColor
        self.namespace = namespace
        self.syncDeviceID = syncDeviceID
        self.syncDatabaseVersion = syncDatabaseVersion
        self.syncDatabaseDirty = syncDatabaseDirty
        self.appLanguage = appLanguage
        self.launchAtLogin = launchAtLogin
        self.applicationIconMode = applicationIconMode
        self.allNotesCollapsed = allNotesCollapsed
        self.syncSession = syncSession
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.defaults
        if let rawWindowLevel = try container.decodeIfPresent(String.self, forKey: .noteWindowLevel) {
            noteWindowLevel = NoteWindowLevel.value(for: rawWindowLevel)
        } else {
            noteWindowLevel = defaults.noteWindowLevel
        }
        defaultNoteColor = try container.decodeIfPresent(String.self, forKey: .defaultNoteColor) ?? defaults.defaultNoteColor
        namespace = try container.decodeIfPresent(String.self, forKey: .namespace)
            ?? container.decodeIfPresent(String.self, forKey: .username)
            ?? defaults.namespace
        syncDeviceID = try container.decodeIfPresent(String.self, forKey: .syncDeviceID) ?? defaults.syncDeviceID
        syncDatabaseVersion = try container.decodeIfPresent(Int.self, forKey: .syncDatabaseVersion) ?? 0
        syncDatabaseDirty = try container.decodeIfPresent(Bool.self, forKey: .syncDatabaseDirty) ?? false
        appLanguage = try container.decodeIfPresent(String.self, forKey: .appLanguage) ?? defaults.appLanguage
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        applicationIconMode = try container.decodeIfPresent(
            LeafiyApplicationIconMode.self,
            forKey: .applicationIconMode
        ) ?? defaults.applicationIconMode
        allNotesCollapsed = try container.decodeIfPresent(Bool.self, forKey: .allNotesCollapsed) ?? defaults.allNotesCollapsed
        syncSession = try container.decodeIfPresent(SyncSession.self, forKey: .syncSession)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(noteWindowLevel, forKey: .noteWindowLevel)
        try container.encode(defaultNoteColor, forKey: .defaultNoteColor)
        try container.encode(namespace, forKey: .namespace)
        try container.encode(syncDeviceID, forKey: .syncDeviceID)
        try container.encode(syncDatabaseVersion, forKey: .syncDatabaseVersion)
        try container.encode(syncDatabaseDirty, forKey: .syncDatabaseDirty)
        try container.encode(appLanguage, forKey: .appLanguage)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(applicationIconMode, forKey: .applicationIconMode)
        try container.encode(allNotesCollapsed, forKey: .allNotesCollapsed)
        try container.encodeIfPresent(syncSession, forKey: .syncSession)
    }


    public static var defaults: AppSettings { AppSettings() }

    public func normalized() -> AppSettings {
        var normalized = self
        if !NoteColor.allowedRawValues.contains(normalized.defaultNoteColor) {
            normalized.defaultNoteColor = NoteColor.white.rawValue
        }
        normalized.namespace = normalized.namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.syncDeviceID = normalized.syncDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.syncDeviceID.isEmpty {
            normalized.syncDeviceID = UUID().uuidString.lowercased()
        }
        normalized.syncDatabaseVersion = max(normalized.syncDatabaseVersion, 0)
        if AppLanguage(rawValue: normalized.appLanguage) == nil {
            normalized.appLanguage = AppLanguage.system.rawValue
        }
        return normalized
    }
}
