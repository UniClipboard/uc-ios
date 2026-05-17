import Foundation
#if canImport(UniClipboardModels)
// SwiftPM build: model types live in a separate target. The Xcode app
// target compiles everything as one module, so no import is needed.
import UniClipboardModels
#endif

/// Probes a server's reachability + credentials via `getClipboard`.
/// Shared by SetupFlow's first-run form and Settings' add/edit forms so the
/// "测试连接" semantics are identical everywhere.
///
/// Spec §2.1 treats 404 as "no clipboard published yet" — the server is
/// reachable and auth is fine, which is what the user is testing. We map
/// that case to `.success`.
enum ConnectionTester {
    enum Result: Equatable, Sendable {
        case success
        case authFailed
        case unreachable
        case missingFields
    }

    static func test(
        url: String,
        username: String,
        password: String,
        trustInsecureCert: Bool
    ) async -> Result {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty || username.isEmpty || password.isEmpty {
            return .missingFields
        }
        let probe = ServerConfig(
            id: "probe",
            url: trimmedURL,
            username: username,
            password: password
        )
        let client: SyncClipboardClient
        do {
            client = try SyncClipboardClient(server: probe, trustInsecureCert: trustInsecureCert)
        } catch {
            return .unreachable
        }
        do {
            _ = try await client.getClipboard()
            return .success
        } catch let e as SyncError {
            switch e.kind {
            case .notFound:    return .success
            case .authFailed:  return .authFailed
            default:           return .unreachable
            }
        } catch {
            return .unreachable
        }
    }
}
