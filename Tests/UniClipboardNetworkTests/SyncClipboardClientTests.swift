import XCTest
import UniClipboardModels
@testable import UniClipboardNetwork

final class SyncClipboardClientTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - URL normalization (§1.1)

    func test_normalizeBaseURL_appendsTrailingSlashWhenMissing() throws {
        let url = try SyncClipboardClient.normalizeBaseURL("https://example.com")
        XCTAssertEqual(url.absoluteString, "https://example.com/")
    }

    func test_normalizeBaseURL_isIdempotentWhenAlreadySlashed() throws {
        let url = try SyncClipboardClient.normalizeBaseURL("https://example.com/")
        XCTAssertEqual(url.absoluteString, "https://example.com/")
    }

    func test_normalizeBaseURL_trimsSurroundingWhitespace() throws {
        let url = try SyncClipboardClient.normalizeBaseURL("  https://example.com  ")
        XCTAssertEqual(url.absoluteString, "https://example.com/")
    }

    func test_normalizeBaseURL_rejectsEmptyString() {
        XCTAssertThrowsError(try SyncClipboardClient.normalizeBaseURL("")) { e in
            XCTAssertEqual((e as? SyncError)?.kind, .invalidURL)
        }
    }

    func test_normalizeBaseURL_rejectsNonHTTPScheme() {
        XCTAssertThrowsError(try SyncClipboardClient.normalizeBaseURL("ftp://example.com")) { e in
            XCTAssertEqual((e as? SyncError)?.kind, .invalidURL)
        }
    }

    func test_normalizeBaseURL_rejectsHostlessString() {
        XCTAssertThrowsError(try SyncClipboardClient.normalizeBaseURL("not-a-url")) { e in
            XCTAssertEqual((e as? SyncError)?.kind, .invalidURL)
        }
    }

    func test_normalizeBaseURL_acceptsPortAndPath() throws {
        let url = try SyncClipboardClient.normalizeBaseURL("https://nas.local:5033/sync")
        XCTAssertEqual(url.absoluteString, "https://nas.local:5033/sync/")
    }

    // MARK: - Basic auth header (§1.2)

    func test_basicAuthHeader_matchesSpecExample() {
        // base64("alice:secret") = "YWxpY2U6c2VjcmV0"
        XCTAssertEqual(
            SyncClipboardClient.basicAuthHeader(username: "alice", password: "secret"),
            "Basic YWxpY2U6c2VjcmV0"
        )
    }

    func test_basicAuthHeader_handlesUTF8Credentials() {
        // base64(utf8("用户:密码"))
        let header = SyncClipboardClient.basicAuthHeader(username: "用户", password: "密码")
        let expected = "Basic " + Data("用户:密码".utf8).base64EncodedString()
        XCTAssertEqual(header, expected)
    }

    // MARK: - GET SyncClipboard.json (§2.1)

    func test_getClipboard_decodesHappyPath() async throws {
        let payload: [String: Any] = [
            "type": "Text",
            "text": "hello",
            "hasData": false,
            "size": 5
        ]
        MockURLProtocol.handler = { req in
            let body = try JSONSerialization.data(withJSONObject: payload)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            return (resp, body)
        }
        let client = try makeClient()
        let clip = try await client.getClipboard()
        XCTAssertEqual(clip.type, .text)
        XCTAssertEqual(clip.text, "hello")
        XCTAssertEqual(clip.size, 5)
        XCTAssertFalse(clip.hasData)
    }

    func test_getClipboard_attachesBasicAuthHeader() async throws {
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }
        let client = try makeClient(username: "alice", password: "secret")
        do {
            _ = try await client.getClipboard()
            XCTFail("expected notFound")
        } catch let e as SyncError {
            XCTAssertEqual(e.kind, .notFound)
        }
        let header = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(header, "Basic YWxpY2U6c2VjcmV0")
    }

    func test_getClipboard_hitsExpectedPath() async throws {
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }
        let client = try makeClient(baseURLString: "https://nas.local:5033/")
        _ = try? await client.getClipboard()
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString,
                       "https://nas.local:5033/SyncClipboard.json")
    }

    func test_getClipboard_returns401AsAuthFailed() async {
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }
        await assertThrowsKind(.authFailed) { try await self.makeClient().getClipboard() }
    }

    func test_getClipboard_returns404AsNotFound() async {
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }
        await assertThrowsKind(.notFound) { try await self.makeClient().getClipboard() }
    }

    func test_getClipboard_returns500AsServerError() async {
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }
        await assertThrowsKind(.serverError(500)) { try await self.makeClient().getClipboard() }
    }

    func test_getClipboard_returnsOther4xxAsProtocolError() async {
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 418, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }
        await assertThrowsKind(.protocolError(418)) { try await self.makeClient().getClipboard() }
    }

    func test_getClipboard_malformedJSONFailsAsDecodingFailed() async {
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("not-json".utf8))
        }
        await assertThrowsKind(.decodingFailed) { try await self.makeClient().getClipboard() }
    }

    // MARK: - Helpers

    private func makeClient(
        baseURLString: String = "https://example.com/",
        username: String = "u",
        password: String = "p"
    ) throws -> SyncClipboardClient {
        let cfg = ServerConfig(
            id: "test-id",
            name: nil,
            url: baseURLString,
            username: username,
            password: password,
            autoSwitchWifiNames: []
        )
        return try SyncClipboardClient(server: cfg, trustInsecureCert: false, session: MockURLProtocol.session())
    }

    private func assertThrowsKind(
        _ expected: SyncError.Kind,
        file: StaticString = #file, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected SyncError.\(expected)", file: file, line: line)
        } catch let e as SyncError {
            XCTAssertEqual(e.kind, expected, file: file, line: line)
        } catch {
            XCTFail("expected SyncError, got \(error)", file: file, line: line)
        }
    }
}
