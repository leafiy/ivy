import AppKit
import AuthenticationServices
import Foundation
import IvyCore
import Security

@MainActor
final class AccountSyncController: NSObject,
    ObservableObject,
    ASWebAuthenticationPresentationContextProviding
{
    @Published private(set) var account: AuthUser?
    @Published private(set) var providers = AuthProviderConfiguration(
        passwordless: AuthProviderStatus(enabled: true),
        email: AuthProviderStatus(enabled: false),
        google: AuthProviderStatus(enabled: false)
    )
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published private(set) var syncStatus = L("Not signed in")
    @Published private(set) var noteDatabaseBytes: Int64 = 0

    var onDatabaseImported: (() -> Void)?

    private weak var owner: IvyModel?
    private let noteStore: NoteStore?
    private let tokenStore = AuthTokenStore()
    private var contentObserver: NSObjectProtocol?
    private var syncTask: Task<Void, Never>?
    private var oauthSession: ASWebAuthenticationSession?
    private var changeGeneration = 0
    private var started = false
    private var lastUploadedSnapshotHash: UInt64?

    init(owner: IvyModel, noteStore: NoteStore?) {
        self.owner = owner
        self.noteStore = noteStore
        super.init()
        if let noteStore {
            contentObserver = NotificationCenter.default.addObserver(
                forName: NoteStore.contentDidChangeNotification,
                object: noteStore,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.contentDidChange() }
            }
        }
    }

    deinit {
        if let contentObserver { NotificationCenter.default.removeObserver(contentObserver) }
        syncTask?.cancel()
    }

    /// Current sync token for API calls made outside this controller
    /// (attachment uploads). Nil when signed out.
    func clientAuthToken() -> String? {
        tokenStore.load()
    }

    var noteDatabaseUsageMB: Double {
        Double(noteDatabaseBytes) / 1024 / 1024
    }

    var attachmentUsageMB: Double {
        account?.usage.attachmentMB ?? 0
    }

    var noteDatabaseLimitMB: Double {
        account?.quota.noteDatabaseLimitMB ?? 10
    }

    var attachmentLimitMB: Double {
        account?.quota.attachmentLimitMB ?? 50
    }

    func start() {
        guard !started else { return }
        started = true
        Task {
            await refreshLocalDatabaseSize()
            await loadProviderConfiguration()
            guard let token = tokenStore.load() else { return }
            do {
                let user = try await client().me(token: token)
                account = user
                syncStatus = L("Checking for changes")
                await synchronize()
            } catch {
                tokenStore.delete()
                account = nil
                syncStatus = L("Sign in to sync")
                message = error.localizedDescription
            }
        }
    }

    func loadProviderConfiguration() async {
        do {
            providers = try await client().authConfiguration()
        } catch {
            syncStatus = L("Server unavailable")
        }
    }

    func enter(namespace: String) {
        performAuth {
            try await self.client().enter(namespace: namespace, device: self.device())
        }
    }

    func sendEmailCode(email: String) {
        perform {
            _ = try await self.client().sendEmailCode(to: email)
            self.message = L("Verification code sent")
        }
    }

    func registerWithEmail(email: String, code: String, password: String) {
        performAuth {
            try await self.client().register(
                email: email,
                code: code,
                password: password,
                device: self.device()
            )
        }
    }

    func signInWithEmail(email: String, password: String) {
        performAuth {
            try await self.client().login(email: email, password: password, device: self.device())
        }
    }

    func signInWithGoogle() {
        perform {
            let authorizationURL = try await self.client().startGoogleOAuth(device: self.device())
            try await self.openOAuthAuthorization(authorizationURL, failureMessage: L("Google login failed"))
        }
    }

    func syncNow() {
        syncTask?.cancel()
        syncTask = Task { await synchronize() }
    }

    func signOut() {
        syncTask?.cancel()
        tokenStore.delete()
        account = nil
        lastUploadedSnapshotHash = nil
        syncStatus = L("Not signed in")
        owner?.updateSettings {
            $0.syncDatabaseVersion = 0
            $0.syncDatabaseDirty = false
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    private func contentDidChange() {
        changeGeneration += 1
        owner?.updateSettings { $0.syncDatabaseDirty = true }
        Task { await refreshLocalDatabaseSize() }
        scheduleSync()
    }

    private func scheduleSync() {
        guard account != nil, tokenStore.load() != nil else { return }
        syncTask?.cancel()
        syncStatus = L("Waiting for changes")
        syncTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await synchronize()
        }
    }

    /// One sync round: pull-and-merge whatever the server has ahead of us,
    /// then push our dirty notes on top of that version. A 409 from the server
    /// means another device pushed in between — pull again, merge, retry.
    private func synchronize() async {
        guard
            let noteStore,
            let owner,
            let token = tokenStore.load()
        else { return }

        isWorking = true
        defer { isWorking = false }
        do {
            var remote = try await client().databaseStatus(token: token)
            var conflictRetries = 0
            while true {
                try await pullIfNeeded(remote: remote, noteStore: noteStore, owner: owner)

                guard try noteStore.hasDirtyNotes() else {
                    owner.updateSettings { $0.syncDatabaseDirty = false }
                    break
                }
                syncStatus = L("Uploading notes database")
                let generation = changeGeneration
                do {
                    try await uploadSnapshot(noteStore: noteStore, token: token, owner: owner)
                } catch SyncClientError.conflict(let current) {
                    conflictRetries += 1
                    guard conflictRetries <= Self.maxConflictRetries else {
                        throw SyncClientError.conflict(current)
                    }
                    if let current {
                        remote = current
                    } else {
                        remote = try await client().databaseStatus(token: token)
                    }
                    continue
                }
                let stillDirty = try noteStore.hasDirtyNotes()
                owner.updateSettings { $0.syncDatabaseDirty = stillDirty }
                if stillDirty || generation != changeGeneration { scheduleSync() }
                break
            }

            account = try await client().me(token: token)
            syncStatus = L("Up to date")
            message = nil
        } catch SyncClientError.noteDatabaseTooLarge {
            syncStatus = L("10 MB limit reached. Changes are kept on this Mac.")
        } catch {
            syncStatus = L("Sync paused")
            message = error.localizedDescription
        }
    }

    private static let maxConflictRetries = 3

    private func pullIfNeeded(remote: DatabaseSyncInfo, noteStore: NoteStore, owner: IvyModel) async throws {
        let settings = owner.settings
        guard remote.version > settings.syncDatabaseVersion else { return }
        if remote.sourceDeviceId == settings.syncDeviceID {
            // The server holds our own earlier upload (we crashed before
            // recording it); the content is already local.
            owner.updateSettings { $0.syncDatabaseVersion = remote.version }
            return
        }
        guard remote.downloadURL != nil else { return }

        syncStatus = L("Downloading notes database")
        let data = try await client().downloadDatabase(remote)
        let hasLocalChanges = try noteStore.hasDirtyNotes()
        try withTemporaryDatabase(data: data) { url in
            if hasLocalChanges {
                try noteStore.mergeContent(from: url)
            } else {
                try noteStore.replaceContent(from: url)
            }
        }
        owner.updateSettings { $0.syncDatabaseVersion = remote.version }
        onDatabaseImported?()
        await refreshLocalDatabaseSize()
    }

    private func uploadSnapshot(noteStore: NoteStore, token: String, owner: IvyModel) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = directory.appendingPathComponent("notes.sqlite")

        // Captured before the snapshot: a note edited between the two reads
        // ends up inside the snapshot but keeps its dirty flag, so the next
        // round re-uploads it rather than losing it.
        let dirtyAtSnapshot = try noteStore.fetchDirty()
        try noteStore.makeSyncSnapshot(at: snapshot)
        let data = try Data(contentsOf: snapshot)
        noteDatabaseBytes = Int64(data.count)
        guard Int64(data.count) <= SyncLimits.noteDatabaseBytes else {
            throw SyncClientError.noteDatabaseTooLarge(bytes: Int64(data.count))
        }

        let hash = Self.contentHash(data)
        if hash == lastUploadedSnapshotHash, owner.settings.syncDatabaseVersion > 0 {
            // Byte-identical to what the server already has; just settle the
            // dirty flags.
            try noteStore.markClean(upToDateWith: dirtyAtSnapshot)
            return
        }

        let uploaded = try await client().uploadDatabase(
            token: token,
            deviceID: owner.settings.syncDeviceID,
            baseVersion: owner.settings.syncDatabaseVersion,
            databaseData: data
        )
        lastUploadedSnapshotHash = hash
        try noteStore.markClean(upToDateWith: dirtyAtSnapshot)
        owner.updateSettings { $0.syncDatabaseVersion = uploaded.version }
    }

    /// FNV-1a; collision strength is irrelevant here, this only skips
    /// re-uploading a snapshot this process already sent.
    private static func contentHash(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return hash
    }

    private func refreshLocalDatabaseSize() async {
        guard let noteStore else { return }
        do {
            noteDatabaseBytes = try noteStore.syncSnapshotSizeBytes()
        } catch {
            message = error.localizedDescription
        }
    }

    /// Version 0 forces the first sync to pull whatever the account holds.
    /// Local notes carry their own per-note dirty flags, so anything created
    /// offline merges into the account instead of being replaced.
    private func completeAuth(_ response: AuthResponse) async throws {
        try tokenStore.save(response.token)
        account = response.user
        lastUploadedSnapshotHash = nil
        owner?.updateSettings {
            if let namespace = response.user.namespace {
                $0.namespace = namespace
            }
            $0.syncDatabaseVersion = 0
        }
        syncStatus = L("Checking for changes")
        await synchronize()
    }

    private func completeAuthToken(_ token: String) async throws {
        try tokenStore.save(token)
        let user = try await client().me(token: token)
        account = user
        lastUploadedSnapshotHash = nil
        owner?.updateSettings {
            if let namespace = user.namespace {
                $0.namespace = namespace
            }
            $0.syncDatabaseVersion = 0
        }
        await synchronize()
    }

    private func performAuth(_ operation: @escaping () async throws -> AuthResponse) {
        perform {
            let response = try await operation()
            try await self.completeAuth(response)
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try await operation()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func openOAuthAuthorization(_ url: URL, failureMessage: String) async throws {
        defer { oauthSession = nil }
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "ivy") { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: SyncClientError.invalidResponse)
                }
            }
            session.presentationContextProvider = self
            oauthSession = session
            guard session.start() else {
                continuation.resume(throwing: SyncClientError.invalidResponse)
                return
            }
        }
        let values = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let token = values.first(where: { $0.name == "token" })?.value {
            try await completeAuthToken(token)
            return
        }
        let errorMessage = values.first(where: { $0.name == "message" })?.value ?? failureMessage
        throw AccountSyncError(message: errorMessage)
    }

    private func client() -> SyncClient {
        SyncClient()
    }

    private func device() -> SyncDevice {
        SyncDevice(
            id: owner?.settings.syncDeviceID ?? UUID().uuidString.lowercased(),
            name: Host.current().localizedName ?? L("Mac")
        )
    }

    private func withTemporaryDatabase<T>(data: Data, operation: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.sqlite")
        try data.write(to: url, options: .atomic)
        return try operation(url)
    }
}

private struct AccountSyncError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class AuthTokenStore {
    private let service = "com.qiansmile.ivy.sync"
    private let account = "client-token"

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AccountSyncError(message: "Keychain error \(status)")
        }
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
