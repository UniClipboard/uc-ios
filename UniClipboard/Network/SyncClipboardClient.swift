import Foundation
#if canImport(UniClipboardModels)
// SwiftPM build: model types live in a separate target. The Xcode app
// target compiles everything as one module, so no import is needed —
// `canImport` is false there because the project doesn't depend on
// the local SwiftPM package.
import UniClipboardModels
#endif

/// HTTP client for the SyncClipboard wire protocol.
/// Spec: docs/SYNC_PROTOCOL.md §1–§3 (read path only this cycle).
///
/// Not `@MainActor`-isolated so that callers on any actor can `await`
/// without an unnecessary hop. The Xcode app target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is target-specific; the
/// SwiftPM `UniClipboardNetwork` target compiles this file without that
/// default, so don't decorate types here with `@MainActor`.
public final class SyncClipboardClient: @unchecked Sendable {
    private let baseURL: URL
    private let authHeader: String
    private let session: URLSession
    private let ownsSession: Bool

    /// - Parameters:
    ///   - server: profile providing URL + credentials. URL is normalized
    ///     per §1.1 inside the init.
    ///   - trustInsecureCert: when true, the constructed URLSession uses
    ///     a delegate that accepts any server trust — for self-signed
    ///     LAN servers. Ignored when `session` is supplied (caller owns
    ///     trust policy in that case).
    ///   - session: optional pre-built session for tests. When supplied,
    ///     the client does not own its lifetime.
    public init(
        server: ServerConfig,
        trustInsecureCert: Bool,
        session: URLSession? = nil
    ) throws {
        self.baseURL = try Self.normalizeBaseURL(server.url)
        self.authHeader = Self.basicAuthHeader(username: server.username, password: server.password)
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            self.session = Self.makeSession(trustInsecureCert: trustInsecureCert)
            self.ownsSession = true
        }
    }

    deinit {
        if ownsSession { session.invalidateAndCancel() }
    }

    // MARK: - Endpoints

    /// `GET SyncClipboard.json` — pull current clipboard state. Spec §2.1.
    public func getClipboard() async throws -> Clipboard {
        let url = baseURL.appendingPathComponent("SyncClipboard.json")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(req)
        if let err = SyncError.mapHTTPStatus((response as? HTTPURLResponse)?.statusCode ?? -1) {
            throw err
        }
        do {
            return try JSONDecoder().decode(Clipboard.self, from: data)
        } catch {
            throw SyncError(kind: .decodingFailed, underlying: "\(error)")
        }
    }

    // MARK: - Internals

    private func perform(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch let e as URLError {
            throw SyncError.mapURLError(e)
        } catch {
            throw SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    // MARK: - Helpers (testable as static)

    /// §1.1 — trim whitespace, append trailing slash if missing, validate
    /// scheme is http or https.
    static func normalizeBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SyncError(kind: .invalidURL) }
        let withSlash = trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
        guard let url = URL(string: withSlash) else { throw SyncError(kind: .invalidURL) }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else {
            throw SyncError(kind: .invalidURL)
        }
        return url
    }

    /// §1.2 — `Basic <base64(utf8(user:pass))>`.
    static func basicAuthHeader(username: String, password: String) -> String {
        let pair = "\(username):\(password)"
        let encoded = Data(pair.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    private static func makeSession(trustInsecureCert: Bool) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        // §1 timeouts: 5s connect, 5min receive (read path doesn't push, send timeout
        // is irrelevant here; align with receive).
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 5 * 60
        if trustInsecureCert {
            let delegate = TrustingDelegate()
            return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        }
        return URLSession(configuration: cfg)
    }
}

/// Accepts any server trust — used only when the user opts into
/// "trust insecure cert" for LAN/self-signed servers (§1).
private final class TrustingDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @Sendable @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
