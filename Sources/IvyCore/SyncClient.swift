import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SyncLimits {
    public static let noteDatabaseBytes: Int64 = 10 * 1024 * 1024
    public static let attachmentBytes: Int64 = 50 * 1024 * 1024
}

public struct SyncDevice: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct NamespaceLoginRequest: Codable, Equatable, Sendable {
    public var namespace: String
    public var device: SyncDevice

    public init(namespace: String, device: SyncDevice) {
        self.namespace = namespace
        self.device = device
    }
}
public struct RefreshSessionRequest: Codable, Equatable, Sendable {
    public var refreshToken: String
    public var device: SyncDevice
}

public struct OAuthCodeExchangeRequest: Codable, Equatable, Sendable {
    public var code: String
}


public struct OAuthStartRequest: Codable, Equatable, Sendable {
    public var device: SyncDevice

    public init(device: SyncDevice) {
        self.device = device
    }
}

public struct EmailLoginRequest: Codable, Equatable, Sendable {
    public var email: String
    public var password: String
    public var device: SyncDevice
}

public struct EmailRegistrationRequest: Codable, Equatable, Sendable {
    public var email: String
    public var code: String
    public var password: String
    public var device: SyncDevice
}

public struct GoogleOAuthRequest: Codable, Equatable, Sendable {
    public var idToken: String
    public var device: SyncDevice

    public init(idToken: String, device: SyncDevice) {
        self.idToken = idToken
        self.device = device
    }
}

public struct AuthProviderStatus: Codable, Equatable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

public struct AuthProviderConfiguration: Codable, Equatable, Sendable {
    public var passwordless: AuthProviderStatus
    public var email: AuthProviderStatus
    public var google: AuthProviderStatus

    public init(
        passwordless: AuthProviderStatus,
        email: AuthProviderStatus,
        google: AuthProviderStatus
    ) {
        self.passwordless = passwordless
        self.email = email
        self.google = google
    }
}

public struct OAuthStartResponse: Codable, Equatable, Sendable {
    public var authorizationURL: URL
}

public struct AuthResponse: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresIn: Int
    public var created: Bool
    public var user: AuthUser
}

public struct AuthUser: Codable, Equatable, Sendable {
    public var id: String
    public var accountType: String
    public var namespace: String?
    public var email: String?
    public var methods: [String]
    public var subscription: UserSubscription
    public var quota: UserQuota
    public var usage: UserUsage
    public var database: DatabaseSyncInfo
    public var devices: [UserDevice]
}

public struct UserSubscription: Codable, Equatable, Sendable {
    public var planId: String
    public var expiresAt: Date?
}

public struct UserQuota: Codable, Equatable, Sendable {
    public var deviceLimit: Int
    public var storageLimitMB: Double
    public var noteDatabaseLimitMB: Double
    public var attachmentLimitMB: Double

    private enum CodingKeys: String, CodingKey {
        case deviceLimit, storageLimitMB, noteDatabaseLimitMB, attachmentLimitMB
    }

    public init(
        deviceLimit: Int,
        noteDatabaseLimitMB: Double = 10,
        attachmentLimitMB: Double = 50
    ) {
        self.deviceLimit = deviceLimit
        self.storageLimitMB = noteDatabaseLimitMB
        self.noteDatabaseLimitMB = noteDatabaseLimitMB
        self.attachmentLimitMB = attachmentLimitMB
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceLimit = try container.decode(Int.self, forKey: .deviceLimit)
        storageLimitMB = try container.decodeIfPresent(Double.self, forKey: .storageLimitMB) ?? 10
        noteDatabaseLimitMB = try container.decodeIfPresent(Double.self, forKey: .noteDatabaseLimitMB)
            ?? storageLimitMB
        attachmentLimitMB = try container.decodeIfPresent(Double.self, forKey: .attachmentLimitMB) ?? 50
    }
}

public struct UserUsage: Codable, Equatable, Sendable {
    public var devices: Int
    public var storageMB: Double
    public var noteDatabaseMB: Double
    public var attachmentMB: Double

    private enum CodingKeys: String, CodingKey {
        case devices, storageMB, noteDatabaseMB, attachmentMB
    }

    public init(devices: Int, noteDatabaseMB: Double = 0, attachmentMB: Double = 0) {
        self.devices = devices
        self.storageMB = noteDatabaseMB
        self.noteDatabaseMB = noteDatabaseMB
        self.attachmentMB = attachmentMB
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devices = try container.decode(Int.self, forKey: .devices)
        storageMB = try container.decodeIfPresent(Double.self, forKey: .storageMB) ?? 0
        noteDatabaseMB = try container.decodeIfPresent(Double.self, forKey: .noteDatabaseMB) ?? storageMB
        attachmentMB = try container.decodeIfPresent(Double.self, forKey: .attachmentMB) ?? 0
    }
}

public struct UserDevice: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var lastSeenAt: Date
}

public struct DatabaseSyncInfo: Codable, Equatable, Sendable {
    public var version: Int
    public var sizeBytes: Int64
    public var updatedAt: Date?
    public var downloadURL: URL?
    public var sourceDeviceId: String?

    public init(
        version: Int = 0,
        sizeBytes: Int64 = 0,
        updatedAt: Date? = nil,
        downloadURL: URL? = nil,
        sourceDeviceId: String? = nil
    ) {
        self.version = version
        self.sizeBytes = sizeBytes
        self.updatedAt = updatedAt
        self.downloadURL = downloadURL
        self.sourceDeviceId = sourceDeviceId
    }
}

public struct DatabaseSyncResponse: Codable, Equatable, Sendable {
    public var database: DatabaseSyncInfo
}

public struct EmailCodeResponse: Codable, Equatable, Sendable {
    public var sent: Bool
    public var expiresIn: Int
}

public struct AttachmentUploadFile: Equatable, Sendable {
    public var filename: String
    public var contentType: String
    public var data: Data

    public init(filename: String, contentType: String, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

private struct AttachmentUploadAuthorization: Decodable {
    var uploadURL: URL
    var authorization: String
    var filePath: String
}

private struct DirectAttachmentUploadResponse: Decodable {
    var urls: [URL]
    var uuids: [String]
}

private struct AttachmentRegistrationRequest: Encodable {
    struct Item: Encodable {
        var url: String
        var uuid: String
        var name: String
        var sizeBytes: Int64
        var contentType: String
    }

    var files: [Item]
}

public struct AttachmentUploadResponse: Codable, Equatable, Sendable {
    public var urls: [URL]
    public var uuids: [String]
    /// Per-file metadata (OSS URL, thumbnail, name, size). Empty when talking
    /// to an API predating attachment metadata; callers then fall back to `urls`.
    public var attachments: [NoteAttachment]

    private enum CodingKeys: String, CodingKey {
        case urls, uuids, attachments
    }

    public init(urls: [URL], uuids: [String], attachments: [NoteAttachment] = []) {
        self.urls = urls
        self.uuids = uuids
        self.attachments = attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urls = try container.decode([URL].self, forKey: .urls)
        uuids = try container.decode([String].self, forKey: .uuids)
        attachments = try container.decodeIfPresent([NoteAttachment].self, forKey: .attachments) ?? []
    }
}

public struct AttachmentQuota: Codable, Equatable, Sendable {
    public var limitBytes: Int64
    public var usedBytes: Int64
    public var remainingBytes: Int64

    public init(limitBytes: Int64, usedBytes: Int64, remainingBytes: Int64) {
        self.limitBytes = limitBytes
        self.usedBytes = usedBytes
        self.remainingBytes = remainingBytes
    }
}

public struct AttachmentDeleteResponse: Codable, Equatable, Sendable {
    public var deleted: Bool
    public var freedBytes: Int64?
}

public final class SyncClient: @unchecked Sendable {
    public static let apiBaseURL = URL(string: "https://ivy-api.leafiy.com")!

    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public convenience init(session: URLSession = .shared) {
        self.init(baseURL: Self.apiBaseURL, session: session)
    }

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            try APIJSON.encodeDate(date, encoder: encoder)
        }
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try APIJSON.decodeDate(decoder)
        }
    }

    public func authConfiguration() async throws -> AuthProviderConfiguration {
        try await send(makeRequest(path: "/api/v1/auth/config", method: "GET"), decoding: AuthProviderConfiguration.self)
    }

    public func joinNamespace(namespace: String, device: SyncDevice) async throws -> AuthResponse {
        try await send(
            makeNamespaceLoginRequest(namespace: namespace, device: device),
            decoding: AuthResponse.self
        )
    }

    public func createNamespace(namespace: String, device: SyncDevice) async throws -> AuthResponse {
        try await send(
            makeNamespaceCreationRequest(namespace: namespace, device: device),
            decoding: AuthResponse.self
        )
    }

    public func login(email: String, password: String, device: SyncDevice) async throws -> AuthResponse {
        let request = try makeJSONRequest(
            path: "/api/v1/auth/login/email",
            bearerToken: nil,
            body: EmailLoginRequest(email: email, password: password, device: device)
        )
        return try await send(request, decoding: AuthResponse.self)
    }

    public func sendEmailCode(to email: String) async throws -> EmailCodeResponse {
        let request = try makeJSONRequest(
            path: "/api/v1/auth/email-code",
            bearerToken: nil,
            body: ["email": email]
        )
        return try await send(request, decoding: EmailCodeResponse.self)
    }

    public func register(
        email: String,
        code: String,
        password: String,
        device: SyncDevice
    ) async throws -> AuthResponse {
        let request = try makeJSONRequest(
            path: "/api/v1/auth/register",
            bearerToken: nil,
            body: EmailRegistrationRequest(
                email: email,
                code: code,
                password: password,
                device: device
            )
        )
        return try await send(request, decoding: AuthResponse.self)
    }

    public func authenticateWithGoogle(
        idToken: String,
        device: SyncDevice
    ) async throws -> AuthResponse {
        let request = try makeJSONRequest(
            path: "/api/v1/auth/oauth/google",
            bearerToken: nil,
            body: GoogleOAuthRequest(idToken: idToken, device: device)
        )
        return try await send(request, decoding: AuthResponse.self)
    }

    public func startGoogleOAuth(device: SyncDevice) async throws -> URL {
        let request = try makeGoogleOAuthStartRequest(device: device)
        return try await send(request, decoding: OAuthStartResponse.self).authorizationURL
    }
    public func exchangeOAuthCode(_ code: String) async throws -> AuthResponse {
        let request = try makeJSONRequest(
            path: "/api/v1/auth/oauth/exchange",
            bearerToken: nil,
            body: OAuthCodeExchangeRequest(code: code)
        )
        return try await send(request, decoding: AuthResponse.self)
    }

    public func refreshSession(refreshToken: String, device: SyncDevice) async throws -> AuthResponse {
        let request = try makeJSONRequest(
            path: "/api/v1/auth/refresh",
            bearerToken: nil,
            body: RefreshSessionRequest(refreshToken: refreshToken, device: device)
        )
        return try await send(request, decoding: AuthResponse.self)
    }

    public func logout(refreshToken: String, device: SyncDevice) async throws {
        let request = try makeJSONRequest(
            path: "/api/v1/auth/logout",
            bearerToken: nil,
            body: RefreshSessionRequest(refreshToken: refreshToken, device: device)
        )
        try await sendWithoutResponse(request)
    }

    public func me(token: String) async throws -> AuthUser {
        let request = makeRequest(path: "/api/v1/auth/me", method: "GET", bearerToken: token)
        return try await send(request, decoding: AuthUser.self)
    }

    public func databaseStatus(token: String) async throws -> DatabaseSyncInfo {
        let request = makeRequest(path: "/api/v1/sync/database", method: "GET", bearerToken: token)
        return try await send(request, decoding: DatabaseSyncResponse.self).database
    }

    /// Uploads a snapshot on top of `baseVersion`. The server refuses the
    /// upload with `SyncClientError.conflict` when another device has synced a
    /// newer version in the meantime; callers then pull, merge, and retry.
    public func uploadDatabase(
        token: String,
        deviceID: String,
        baseVersion: Int,
        databaseData data: Data
    ) async throws -> DatabaseSyncInfo {
        guard Int64(data.count) <= SyncLimits.noteDatabaseBytes else {
            throw SyncClientError.noteDatabaseTooLarge(bytes: Int64(data.count))
        }
        let compressed = SyncCompression.deflate(data)
        let request = makeDatabaseUploadRequest(
            token: token,
            deviceID: deviceID,
            baseVersion: baseVersion,
            databaseData: compressed ?? data,
            contentEncoding: compressed == nil ? nil : SyncCompression.encodingName
        )
        do {
            return try await send(request, decoding: DatabaseSyncResponse.self).database
        } catch SyncClientError.server(let statusCode, let body) where statusCode == 409 {
            throw SyncClientError.conflict(Self.conflictInfo(from: body, decoder: decoder))
        }
    }

    /// The 409 payload carries the server's current database status inside the
    /// error object; missing or undecodable info degrades to nil and callers
    /// re-fetch the status instead.
    static func conflictInfo(from body: Data, decoder: JSONDecoder) -> DatabaseSyncInfo? {
        struct Envelope: Decodable {
            struct Payload: Decodable { var database: DatabaseSyncInfo? }
            var error: Payload?
        }
        return (try? decoder.decode(Envelope.self, from: body))?.error?.database
    }

    public func downloadDatabase(_ database: DatabaseSyncInfo) async throws -> Data {
        guard let url = database.downloadURL else { throw SyncClientError.databaseUnavailable }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else { throw SyncClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw SyncClientError.server(statusCode: response.statusCode, body: data)
        }
        guard Int64(data.count) <= SyncLimits.noteDatabaseBytes else {
            throw SyncClientError.noteDatabaseTooLarge(bytes: Int64(data.count))
        }
        return data
    }

    public func uploadAttachments(token: String, files: [AttachmentUploadFile]) async throws -> AttachmentUploadResponse {
        guard !files.isEmpty, files.count <= 10 else { throw SyncClientError.invalidAttachmentCount }
        let totalBytes = files.reduce(Int64(0)) { $0 + Int64($1.data.count) }
        guard totalBytes <= SyncLimits.attachmentBytes else {
            throw SyncClientError.attachmentsTooLarge(bytes: totalBytes)
        }

        let authorization = try await send(
            makeRequest(
                path: "/api/v1/upload/authorization",
                method: "GET",
                bearerToken: token
            ),
            decoding: AttachmentUploadAuthorization.self
        )

        let boundary = "ivy-attachments-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipartField(name: "filePath", value: authorization.filePath, boundary: boundary)
        for file in files {
            body.appendMultipartFile(
                field: "files",
                filename: file.filename,
                contentType: file.contentType,
                data: file.data,
                boundary: boundary
            )
        }
        body.appendString("--\(boundary)--\r\n")

        var uploadRequest = URLRequest(url: authorization.uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        uploadRequest.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        uploadRequest.setValue(
            authorization.authorization,
            forHTTPHeaderField: "uploader-authorization"
        )
        uploadRequest.httpBody = body
        let uploaded = try await send(uploadRequest, decoding: DirectAttachmentUploadResponse.self)

        guard uploaded.urls.count == files.count, uploaded.uuids.count == files.count else {
            throw SyncClientError.invalidResponse
        }
        let registration = AttachmentRegistrationRequest(
            files: files.indices.map { index in
                AttachmentRegistrationRequest.Item(
                    url: uploaded.urls[index].absoluteString,
                    uuid: uploaded.uuids[index],
                    name: files[index].filename,
                    sizeBytes: Int64(files[index].data.count),
                    contentType: files[index].contentType
                )
            }
        )
        let registrationRequest = try makeJSONRequest(
            path: "/api/v1/upload/files",
            bearerToken: token,
            body: registration
        )
        return try await send(registrationRequest, decoding: AttachmentUploadResponse.self)
    }

    /// Remaining attachment quota; clients must consult this before uploading.
    public func attachmentQuota(token: String) async throws -> AttachmentQuota {
        let request = makeRequest(path: "/api/v1/upload/quota", method: "GET", bearerToken: token)
        return try await send(request, decoding: AttachmentQuota.self)
    }

    /// Removes the server-side attachment record and frees its quota bytes.
    @discardableResult
    public func deleteAttachment(token: String, url: String) async throws -> AttachmentDeleteResponse {
        let request = try makeJSONRequest(
            path: "/api/v1/upload/files",
            method: "DELETE",
            bearerToken: token,
            body: ["url": url]
        )
        return try await send(request, decoding: AttachmentDeleteResponse.self)
    }

    public func makeNamespaceLoginRequest(namespace: String, device: SyncDevice) throws -> URLRequest {
        try makeJSONRequest(
            path: "/api/v1/auth/login/namespace",
            bearerToken: nil,
            body: NamespaceLoginRequest(namespace: namespace, device: device)
        )
    }

    public func makeNamespaceCreationRequest(namespace: String, device: SyncDevice) throws -> URLRequest {
        try makeJSONRequest(
            path: "/api/v1/namespaces",
            bearerToken: nil,
            body: NamespaceLoginRequest(namespace: namespace, device: device)
        )
    }

    public func makeGoogleOAuthStartRequest(device: SyncDevice) throws -> URLRequest {
        try makeJSONRequest(
            path: "/api/v1/auth/oauth/google/start",
            bearerToken: nil,
            body: OAuthStartRequest(device: device)
        )
    }

    public func makeDatabaseUploadRequest(
        token: String,
        deviceID: String,
        baseVersion: Int,
        databaseData: Data,
        contentEncoding: String? = nil
    ) -> URLRequest {
        let boundary = "ivy-database-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipartField(name: "deviceId", value: deviceID, boundary: boundary)
        body.appendMultipartField(name: "baseVersion", value: String(baseVersion), boundary: boundary)
        if let contentEncoding {
            body.appendMultipartField(name: "contentEncoding", value: contentEncoding, boundary: boundary)
        }
        body.appendMultipartFile(
            field: "database",
            filename: "notes.sqlite",
            contentType: "application/vnd.sqlite3",
            data: databaseData,
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")

        var request = makeRequest(path: "/api/v1/sync/database", method: "POST", bearerToken: token)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private func makeJSONRequest<Body: Encodable>(
        path: String,
        method: String = "POST",
        bearerToken: String?,
        body: Body
    ) throws -> URLRequest {
        var request = makeRequest(path: path, method: method, bearerToken: bearerToken)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func makeRequest(path: String, method: String, bearerToken: String? = nil) -> URLRequest {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func url(for path: String) -> URL {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func send<Response: Decodable>(_ request: URLRequest, decoding type: Response.Type) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SyncClientError.server(statusCode: httpResponse.statusCode, body: data)
        }
        return try decoder.decode(Response.self, from: data)
    }
    private func sendWithoutResponse(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SyncClientError.server(statusCode: httpResponse.statusCode, body: data)
        }
    }
}

public enum SyncClientError: LocalizedError {
    case invalidResponse
    case server(statusCode: Int, body: Data)
    case databaseUnavailable
    case noteDatabaseTooLarge(bytes: Int64)
    case attachmentsTooLarge(bytes: Int64)
    case invalidAttachmentCount
    /// Another device uploaded a newer database since our base version. The
    /// payload is the server's current status when the response carried one.
    case conflict(DatabaseSyncInfo?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Sync server returned a non-HTTP response."
        case .conflict:
            return "The notes database changed on another device."
        case .server(let statusCode, let body):
            if let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let error = payload["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            return "Sync server returned HTTP \(statusCode)."
        case .databaseUnavailable:
            return "No synced notes database is available."
        case .noteDatabaseTooLarge:
            return "The notes database is larger than 10 MB and was not synced."
        case .attachmentsTooLarge:
            return "Attachments are larger than 50 MB and were not uploaded."
        case .invalidAttachmentCount:
            return "Choose between 1 and 10 attachments."
        }
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFile(
        field: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        let safeFilename = filename.replacingOccurrences(of: "\"", with: "")
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(safeFilename)\"\r\n")
        appendString("Content-Type: \(contentType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}

enum APIJSON {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func encodeDate(_ date: Date, encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fractionalFormatter.string(from: date))
    }

    static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let date = fractionalFormatter.date(from: value) ?? wholeSecondFormatter.date(from: value) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO8601 date: \(value)"
        )
    }
}
