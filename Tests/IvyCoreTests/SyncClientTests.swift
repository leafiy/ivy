import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import IvyCore

final class SyncClientTests: XCTestCase {
    func testDefaultClientUsesBuildConfigurationAPIEndpoint() throws {
        let client = SyncClient()
        let request = try client.makeNamespaceRequest(
            namespace: "test",
            device: SyncDevice(id: "device-1", name: "Mac")
        )

        #if DEBUG || IVY_DEVELOPMENT_API
        let expectedURL = "http://192.168.52.4:7788/api/v1/auth/login"
        #else
        let expectedURL = "https://ivy-api.tatools.cn/api/v1/auth/login"
        #endif

        XCTAssertEqual(request.url?.absoluteString, expectedURL)
    }

    func testBuildsNamespaceRequestBody() throws {
        let client = SyncClient(baseURL: URL(string: "https://ivy.example")!)
        let request = try client.makeNamespaceRequest(
            namespace: "朋友的周末计划 ✨",
            device: SyncDevice(id: "device-1", name: "MacBook Pro")
        )

        XCTAssertEqual(request.url?.absoluteString, "https://ivy.example/api/v1/auth/login")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(payload["namespace"] as? String, "朋友的周末计划 ✨")
        XCTAssertNil(payload["username"])
        let device = try XCTUnwrap(payload["device"] as? [String: Any])
        XCTAssertEqual(device["id"] as? String, "device-1")
        XCTAssertEqual(device["name"] as? String, "MacBook Pro")
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
}

private final class MockURLProtocol: URLProtocol {
    static var responseData = Data()
    static var statusCode = 200
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        lastRequest = request
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
