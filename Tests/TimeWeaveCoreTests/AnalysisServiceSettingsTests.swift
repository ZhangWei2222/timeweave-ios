import XCTest
@testable import TimeWeaveCore

@MainActor
final class AnalysisServiceSettingsTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)

    func testDefaultLocalAndSavedEnvironmentReloadWithoutLeakingTokenToPreferences() throws {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let vault = MemoryAnalysisTokens()
        let settings = AnalysisServiceSettings(defaults: defaults, tokens: vault)
        XCTAssertEqual(try settings.makeClient().baseURL.absoluteString, "http://127.0.0.1:8787")
        try settings.save(environment: .remote, localAddress: "http://192.168.1.10:8787/", remoteAddress: "https://API.example.com:443/", token: token)
        let reloaded = AnalysisServiceSettings(defaults: defaults, tokens: vault)
        XCTAssertEqual(reloaded.environment, .remote)
        XCTAssertEqual(try reloaded.makeClient().baseURL.absoluteString, "https://api.example.com")
        for value in defaults.persistentDomain(forName: name)!.values {
            let plaintext = (value as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: value)
            XCTAssertFalse(plaintext.contains(token))
        }
        try reloaded.save(environment: .local, localAddress: reloaded.localAddress, remoteAddress: reloaded.remoteAddress, token: nil)
        XCTAssertEqual(try reloaded.makeClient().baseURL.absoluteString, "http://192.168.1.10:8787")
    }

    func testTokenIsBoundToOriginAndPortAndMayBeExplicitlyDeleted() throws {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AnalysisServiceSettings(defaults: defaults, tokens: MemoryAnalysisTokens())
        try settings.save(environment: .remote, localAddress: settings.localAddress, remoteAddress: "https://one.example.com", token: token)
        let revision = settings.revision
        for address in ["https://two.example.com", "https://one.example.com:8443"] {
            XCTAssertThrowsError(try settings.save(environment: .remote, localAddress: settings.localAddress, remoteAddress: address, token: nil))
            XCTAssertEqual(settings.remoteAddress, "https://one.example.com")
            XCTAssertEqual(settings.revision, revision)
        }
        try settings.removeRemoteToken()
        XCTAssertThrowsError(try settings.makeClient())
        XCTAssertNotEqual(settings.revision, revision)
    }

    func testInvalidInputAndKeychainFailureDoNotCommitSettings() throws {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let vault = MemoryAnalysisTokens()
        let settings = AnalysisServiceSettings(defaults: defaults, tokens: vault)
        for invalid in ["", "short", String(repeating: "a", count: 257), String(repeating: "a", count: 31) + "\n", String(repeating: "字", count: 32)] {
            XCTAssertThrowsError(try settings.save(environment: .remote, localAddress: settings.localAddress, remoteAddress: settings.remoteAddress, token: invalid))
        }
        vault.fail = true
        XCTAssertThrowsError(try settings.save(environment: .remote, localAddress: settings.localAddress, remoteAddress: settings.remoteAddress, token: token))
        XCTAssertEqual(settings.environment, .local)
        XCTAssertTrue(defaults.persistentDomain(forName: name)?.isEmpty ?? true)
    }

    func testAddressValidationRejectsSecretURLsPublicHTTPAndNonOrigins() throws {
        for address in ["http://api.example.com", "https://user:pass@api.example.com", "https://api.example.com/v1", "https://api.example.com?q=secret", "https://api.example.com#secret", "https://api.example.com:0", "https://api.example.com:65536", "https:///missing", "file:///tmp", ""] {
            XCTAssertThrowsError(try AnalysisEndpoint(address: address, environment: .remote), address)
        }
        for address in ["http://47.117.119.46:8787", "http://example.com", "http://192.168.1.300", "http://localhost.evil.com"] {
            XCTAssertThrowsError(try AnalysisEndpoint(address: address, environment: .local), address)
        }
        for address in ["http://127.0.0.1:8787", "http://localhost:8787", "http://mac.local:8787", "http://192.168.2.3:8787", "http://10.0.0.1:8787", "http://172.16.0.1:8787", "http://[::1]:8787"] {
            XCTAssertNoThrow(try AnalysisEndpoint(address: address, environment: .local), address)
        }
    }

    private func preferences() -> (UserDefaults, String) {
        let name = "TimeWeave.AnalysisTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

@MainActor
final class MemoryAnalysisTokens: AnalysisTokenStoring {
    var values: [String: String] = [:]
    var fail = false
    func read(origin: String) throws -> String? { if fail { throw AgentClientError.configuration("钥匙串不可用") }; return values[origin] }
    func write(_ token: String, origin: String) throws { if fail { throw AgentClientError.configuration("钥匙串不可用") }; values[origin] = token }
    func delete(origin: String) throws { if fail { throw AgentClientError.configuration("钥匙串不可用") }; values[origin] = nil }
}
