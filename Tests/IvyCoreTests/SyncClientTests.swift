import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import IvyCore

final class SyncClientTests: XCTestCase {
    func testDefaultClientUsesProductionAPIEndpoint() throws {
        let client = SyncClient()
        let request = try client.makeNamespaceLoginRequest(
            namespace: "test",
            device: SyncDevice(id: "device-1", name: "Mac")
        )

        let expectedURL = "https://ivy-api.leafiy.com/api/v1/auth/login/namespace"

        XCTAssertEqual(request.url?.absoluteString, expectedURL)
    }

    func testBuildsNamespaceRequestBody() throws {
        let client = SyncClient(baseURL: URL(string: "https://ivy.example")!)
        let request = try client.makeNamespaceLoginRequest(
            namespace: "朋友的周末计划 ✨",
            device: SyncDevice(id: "device-1", name: "MacBook Pro")
        )

        XCTAssertEqual(request.url?.absoluteString, "https://ivy.example/api/v1/auth/login/namespace")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(payload["namespace"] as? String, "朋友的周末计划 ✨")
        XCTAssertNil(payload["username"])
        let device = try XCTUnwrap(payload["device"] as? [String: Any])
        XCTAssertEqual(device["id"] as? String, "device-1")
        XCTAssertEqual(device["name"] as? String, "MacBook Pro")
    }
    func testNamespaceCreationUsesDedicatedEndpoint() throws {
        let client = SyncClient(baseURL: URL(string: "https://ivy.example")!)
        let request = try client.makeNamespaceCreationRequest(
            namespace: "New Space",
            device: SyncDevice(id: "device-1", name: "MacBook Pro")
        )

        XCTAssertEqual(request.url?.absoluteString, "https://ivy.example/api/v1/namespaces")
        XCTAssertEqual(request.httpMethod, "POST")
    }


    func testGoogleOAuthStartDoesNotContainNamespace() throws {
        let client = SyncClient(baseURL: URL(string: "https://ivy.example")!)
        let request = try client.makeGoogleOAuthStartRequest(
            device: SyncDevice(id: "device-1", name: "MacBook Pro")
        )

        XCTAssertEqual(request.url?.absoluteString, "https://ivy.example/api/v1/auth/oauth/google/start")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(payload["namespace"])
        XCTAssertNil(payload["username"])
        XCTAssertNotNil(payload["device"])
    }

    func testBuildsSingleDatabaseMultipartRequest() throws {
        let client = SyncClient(baseURL: URL(string: "https://ivy.example")!)
        let database = Data("SQLite format 3\0database bytes".utf8)
        let request = client.makeDatabaseUploadRequest(
            token: "jwt-token",
            deviceID: "device-1",
            baseVersion: 7,
            databaseData: database
        )

        XCTAssertEqual(request.url?.absoluteString, "https://ivy.example/api/v1/sync/database")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-token")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)

        let body = try XCTUnwrap(request.httpBody)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"database\"; filename=\"notes.sqlite\""))
        XCTAssertTrue(bodyText.contains("name=\"deviceId\""))
        XCTAssertTrue(bodyText.contains("device-1"))
        XCTAssertTrue(bodyText.contains("name=\"baseVersion\""))
        XCTAssertTrue(bodyText.contains("\r\n7\r\n"))
        XCTAssertFalse(bodyText.contains("name=\"contentEncoding\""))
        XCTAssertFalse(bodyText.contains("\"notes\":"))
        XCTAssertTrue(body.range(of: database) != nil)
    }

    func testDatabaseUploadRequestCarriesContentEncodingWhenCompressed() throws {
        let client = SyncClient(baseURL: URL(string: "https://ivy.example")!)
        let request = client.makeDatabaseUploadRequest(
            token: "jwt-token",
            deviceID: "device-1",
            baseVersion: 0,
            databaseData: Data([0x01, 0x02]),
            contentEncoding: SyncCompression.encodingName
        )

        let bodyText = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"contentEncoding\""))
        XCTAssertTrue(bodyText.contains("deflate"))
    }

    func testUploadConflictSurfacesServerDatabaseInfo() async throws {
        MockURLProtocol.responseData = Data("""
        {
          "error": {
            "code": "DATABASE_CONFLICT",
            "message": "The notes database changed on the server.",
            "database": {
              "version": 9,
              "sizeBytes": 1024,
              "updatedAt": "2026-08-09T03:12:00.000Z",
              "downloadURL": "https://oss.example/ivy/user/database/notes.sqlite",
              "sourceDeviceId": "device-2"
            }
          }
        }
        """.utf8)
        MockURLProtocol.statusCode = 409
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SyncClient(baseURL: URL(string: "https://ivy.example")!, session: session)

        do {
            _ = try await client.uploadDatabase(
                token: "jwt-token",
                deviceID: "device-1",
                baseVersion: 3,
                databaseData: Data("SQLite format 3\0database bytes".utf8)
            )
            XCTFail("Expected a conflict error")
        } catch SyncClientError.conflict(let info) {
            XCTAssertEqual(info?.version, 9)
            XCTAssertEqual(info?.sourceDeviceId, "device-2")
            XCTAssertEqual(info?.downloadURL?.host, "oss.example")
        }
    }

    func testDecodesDatabaseSyncResponseWithMockURLProtocol() async throws {
        MockURLProtocol.responseData = Data("""
        {
          "database": {
            "version": 4,
            "sizeBytes": 24576,
            "updatedAt": "2026-08-09T03:12:00.000Z",
            "downloadURL": "https://oss.example/ivy/user/database/notes.sqlite",
            "sourceDeviceId": "device-1"
          }
        }
        """.utf8)
        MockURLProtocol.statusCode = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SyncClient(baseURL: URL(string: "https://ivy.example")!, session: session)

        let database = try await client.databaseStatus(token: "jwt-token")

        XCTAssertEqual(database.version, 4)
        XCTAssertEqual(database.sizeBytes, 24_576)
        XCTAssertEqual(database.downloadURL?.host, "oss.example")
        XCTAssertEqual(database.sourceDeviceId, "device-1")
    }

    func testQuotaDecodingUsesSeparateNoteAndAttachmentLimits() throws {
        let data = Data("""
        {
          "deviceLimit": 2,
          "storageLimitMB": 10,
          "noteDatabaseLimitMB": 10,
          "attachmentLimitMB": 50
        }
        """.utf8)

        let quota = try JSONDecoder().decode(UserQuota.self, from: data)

        XCTAssertEqual(quota.noteDatabaseLimitMB, 10)
        XCTAssertEqual(quota.attachmentLimitMB, 50)
    }

    func testDecodesAttachmentUploadResponseWithMetadata() throws {
        let data = Data("""
        {
          "urls": ["https://oss.example/ivy/u1/attachments/photo.jpg"],
          "uuids": ["uuid-1"],
          "attachments": [
            {
              "url": "https://oss.example/ivy/u1/attachments/photo.jpg",
              "thumbnailUrl": "https://oss.example/ivy/u1/attachments/thumbnails/photo.thumb.webp",
              "name": "photo.jpg",
              "sizeBytes": 120000,
              "contentType": "image/jpeg"
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(AttachmentUploadResponse.self, from: data)

        XCTAssertEqual(response.urls.count, 1)
        XCTAssertEqual(response.attachments.count, 1)
        let attachment = try XCTUnwrap(response.attachments.first)
        XCTAssertEqual(attachment.thumbnailURL, "https://oss.example/ivy/u1/attachments/thumbnails/photo.thumb.webp")
        XCTAssertEqual(attachment.sizeBytes, 120_000)
        XCTAssertTrue(attachment.isImage)
    }

    func testDecodesLegacyAttachmentUploadResponseWithoutMetadata() throws {
        let data = Data("""
        {
          "urls": ["https://oss.example/ivy/u1/attachments/file.zip"],
          "uuids": ["uuid-1"]
        }
        """.utf8)

        let response = try JSONDecoder().decode(AttachmentUploadResponse.self, from: data)

        XCTAssertEqual(response.urls.count, 1)
        XCTAssertTrue(response.attachments.isEmpty)
    }

    func testUploadsAttachmentBytesDirectlyThenRegistersMetadata() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responseProvider = { request in
            switch request.url?.path {
            case "/api/v1/upload/authorization":
                return (200, Data("""
                {
                  "uploadURL": "https://uploader.qiansmile.com/api/upload/files",
                  "authorization": "Uploader direct-token",
                  "filePath": "ivy/user-1/attachments"
                }
                """.utf8))
            case "/api/upload/files":
                return (200, Data("""
                {
                  "urls": ["https://files.qiansmile.com/ivy/user-1/attachments/file.txt"],
                  "uuids": ["uuid-1"]
                }
                """.utf8))
            case "/api/v1/upload/files":
                return (200, Data("""
                {
                  "urls": ["https://files.qiansmile.com/ivy/user-1/attachments/file.txt"],
                  "uuids": ["uuid-1"],
                  "attachments": [{
                    "url": "https://files.qiansmile.com/ivy/user-1/attachments/file.txt",
                    "thumbnailUrl": null,
                    "name": "file.txt",
                    "sizeBytes": 5,
                    "contentType": "text/plain"
                  }]
                }
                """.utf8))
            default:
                return (404, Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SyncClient(baseURL: URL(string: "https://ivy.example")!, session: session)

        let response = try await client.uploadAttachments(
            token: "jwt-token",
            files: [AttachmentUploadFile(
                filename: "file.txt",
                contentType: "text/plain",
                data: Data("hello".utf8)
            )]
        )

        XCTAssertEqual(response.urls.first?.absoluteString, "https://files.qiansmile.com/ivy/user-1/attachments/file.txt")
        XCTAssertEqual(response.attachments.first?.name, "file.txt")
        XCTAssertEqual(MockURLProtocol.requests.count, 3)

        let authorizationRequest = MockURLProtocol.requests[0]
        XCTAssertEqual(authorizationRequest.url?.absoluteString, "https://ivy.example/api/v1/upload/authorization")
        XCTAssertEqual(authorizationRequest.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-token")

        let uploadRequest = MockURLProtocol.requests[1]
        XCTAssertEqual(uploadRequest.url?.host, "uploader.qiansmile.com")
        XCTAssertEqual(uploadRequest.value(forHTTPHeaderField: "uploader-authorization"), "Uploader direct-token")
        XCTAssertNil(uploadRequest.value(forHTTPHeaderField: "Authorization"))
        let uploadBody = String(decoding: try XCTUnwrap(MockURLProtocol.requestBodies[1]), as: UTF8.self)
        XCTAssertTrue(uploadBody.contains("ivy/user-1/attachments"))
        XCTAssertTrue(uploadBody.contains("name=\"files\"; filename=\"file.txt\""))

        let registrationRequest = MockURLProtocol.requests[2]
        XCTAssertEqual(registrationRequest.url?.absoluteString, "https://ivy.example/api/v1/upload/files")
        XCTAssertEqual(registrationRequest.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-token")
        let registration = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(MockURLProtocol.requestBodies[2])
            ) as? [String: Any]
        )
        let registeredFiles = try XCTUnwrap(registration["files"] as? [[String: Any]])
        XCTAssertEqual(registeredFiles.first?["uuid"] as? String, "uuid-1")
        XCTAssertEqual(registeredFiles.first?["sizeBytes"] as? Int, 5)
    }

    func testFetchesAttachmentQuotaBeforeUpload() async throws {
        MockURLProtocol.responseData = Data("""
        {
          "limitBytes": 52428800,
          "usedBytes": 1048576,
          "remainingBytes": 51380224
        }
        """.utf8)
        MockURLProtocol.statusCode = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SyncClient(baseURL: URL(string: "https://ivy.example")!, session: session)

        let quota = try await client.attachmentQuota(token: "jwt-token")

        XCTAssertEqual(quota.limitBytes, 52_428_800)
        XCTAssertEqual(quota.usedBytes, 1_048_576)
        XCTAssertEqual(quota.remainingBytes, 51_380_224)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://ivy.example/api/v1/upload/quota")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET")
    }

    func testDeleteAttachmentSendsJSONBodyWithURL() async throws {
        MockURLProtocol.responseData = Data("""
        { "deleted": true, "freedBytes": 123456 }
        """.utf8)
        MockURLProtocol.statusCode = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SyncClient(baseURL: URL(string: "https://ivy.example")!, session: session)

        let response = try await client.deleteAttachment(
            token: "jwt-token",
            url: "https://oss.example/ivy/u1/attachments/file.zip"
        )

        XCTAssertTrue(response.deleted)
        XCTAssertEqual(response.freedBytes, 123_456)
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://ivy.example/api/v1/upload/files")
        XCTAssertEqual(request.httpMethod, "DELETE")
    }

    func testPrivateAccountDecodesDisplayEmail() throws {
        let data = Data("""
        {
          "id": "account-1",
          "accountType": "private",
          "namespace": null,
          "email": "leafiy.user@example.com",
          "methods": ["google"],
          "subscription": { "planId": "free", "expiresAt": null },
          "quota": {
            "deviceLimit": 2,
            "storageLimitMB": 10,
            "noteDatabaseLimitMB": 10,
            "attachmentLimitMB": 50
          },
          "usage": {
            "devices": 1,
            "storageMB": 0,
            "noteDatabaseMB": 0,
            "attachmentMB": 0
          },
          "database": {
            "version": 0,
            "sizeBytes": 0,
            "updatedAt": null,
            "downloadURL": null,
            "sourceDeviceId": null
          },
          "devices": []
        }
        """.utf8)

        let account = try JSONDecoder().decode(AuthUser.self, from: data)

        XCTAssertEqual(account.email, "leafiy.user@example.com")
        XCTAssertEqual(account.methods, ["google"])
        XCTAssertNil(account.namespace)
    }
    func testRefreshSessionSendsOpaqueTokenWithDeviceBinding() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.statusCode = 401
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SyncClient(baseURL: URL(string: "https://ivy.example")!, session: session)

        do {
            _ = try await client.refreshSession(
                refreshToken: "opaque-refresh-token",
                device: SyncDevice(id: "device-1", name: "MacBook Pro")
            )
            XCTFail("Expected the mock rejection")
        } catch SyncClientError.server(let statusCode, _) {
            XCTAssertEqual(statusCode, 401)
        }

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/auth/refresh")
        let body = try XCTUnwrap(MockURLProtocol.requestBodies.first ?? nil)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["refreshToken"] as? String, "opaque-refresh-token")
        let device = try XCTUnwrap(payload["device"] as? [String: Any])
        XCTAssertEqual(device["id"] as? String, "device-1")
    }

}

private final class MockURLProtocol: URLProtocol {
    static var responseData = Data()
    static var statusCode = 200
    static var lastRequest: URLRequest?
    static var requests: [URLRequest] = []
    static var requestBodies: [Data?] = []
    static var responseProvider: ((URLRequest) -> (statusCode: Int, data: Data))?

    static func reset() {
        responseData = Data()
        statusCode = 200
        lastRequest = nil
        requests = []
        requestBodies = []
        responseProvider = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lastRequest = request
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func body(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }

    override func startLoading() {
        Self.requests.append(request)
        Self.requestBodies.append(Self.body(from: request))
        let result = Self.responseProvider?(request)
            ?? (statusCode: Self.statusCode, data: Self.responseData)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: result.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
