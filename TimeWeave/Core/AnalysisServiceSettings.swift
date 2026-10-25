import Foundation
import Combine
import Security

enum AnalysisEnvironment: String, Codable, CaseIterable, Identifiable {
    case local, remote
    var id: String { rawValue }
    var title: String { self == .local ? "本地" : "远端" }
}

struct AnalysisEndpoint {
    let url: URL
    var origin: String { url.absoluteString }

    init(address: String, environment: AnalysisEnvironment) throws {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw AgentClientError.configuration("请输入完整服务地址（协议、主机及可选端口），不要包含路径、账号、查询参数或片段。")
        }
        if environment == .remote && scheme != "https" {
            throw AgentClientError.configuration("远端地址必须使用 HTTPS，不能明文传输访问令牌。")
        }
        if environment == .local && !Self.isLocalHost(host) {
            throw AgentClientError.configuration("本地地址需使用 localhost、回环地址、192.168／10／172.16–31 内网地址或 .local 主机名。")
        }
        parts.scheme = scheme
        parts.host = host
        parts.path = ""
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        guard let url = parts.url else { throw AgentClientError.configuration("服务地址无效。") }
        self.url = url
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if ["localhost", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") { return true }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        let octets = pieces.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 127 || octets[0] == 10 ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 172 && (16...31).contains(octets[1]))
    }
}

@MainActor
protocol AnalysisTokenStoring {
    func read(origin: String) throws -> String?
    func write(_ token: String, origin: String) throws
    func delete(origin: String) throws
}

@MainActor
struct KeychainAnalysisTokens: AnalysisTokenStoring {
    var service = "com.timeweave.analysis-access"

    private func query(_ origin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: origin]
    }
    func read(origin: String) throws -> String? {
        var request = query(origin)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw AgentClientError.configuration("钥匙串令牌无法读取，请重新填写。")
        }
        return token
    }
    func write(_ token: String, origin: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query(origin) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query(origin).merging(attributes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }
    func delete(origin: String) throws {
        let status = SecItemDelete(query(origin) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw AgentClientError.configuration("无法访问系统钥匙串（\(status)），请检查设备解锁状态及 App 签名权限。")
        }
    }
}

@MainActor
final class AnalysisServiceSettings: ObservableObject {
    @Published private(set) var environment: AnalysisEnvironment = .local
    @Published private(set) var localAddress = "http://127.0.0.1:8787"
    @Published private(set) var remoteAddress = "https://api.super-vivian.top"
    @Published private(set) var revision = 0
    var currentAddress: String { environment == .local ? localAddress : remoteAddress }
    private let defaults: UserDefaults
    private let tokens: any AnalysisTokenStoring
    private let preferencesKey = "analysis.service.v1"

    private struct Preferences: Codable {
        let environment: AnalysisEnvironment
        let localAddress: String
        let remoteAddress: String
    }

    init(defaults: UserDefaults = .standard, tokens: any AnalysisTokenStoring = KeychainAnalysisTokens()) {
        self.defaults = defaults
        self.tokens = tokens
        if let data = defaults.data(forKey: preferencesKey),
           let saved = try? JSONDecoder().decode(Preferences.self, from: data),
           let local = try? AnalysisEndpoint(address: saved.localAddress, environment: .local),
           let remote = try? AnalysisEndpoint(address: saved.remoteAddress, environment: .remote) {
            environment = saved.environment
            localAddress = local.origin
            remoteAddress = remote.origin
        }
    }

    /// nil keeps the token for this exact remote origin. Empty input is invalid.
    func save(environment: AnalysisEnvironment, localAddress: String, remoteAddress: String, token: String?) throws {
        let local = try AnalysisEndpoint(address: localAddress, environment: .local)
        let remote = try AnalysisEndpoint(address: remoteAddress, environment: .remote)
        let data = try JSONEncoder().encode(Preferences(environment: environment, localAddress: local.origin, remoteAddress: remote.origin))
        if let token {
            try Self.validateToken(token)
            try tokens.write(token, origin: remote.origin)
        } else if environment == .remote {
            try Self.validateToken(requiredToken(origin: remote.origin))
        }
        defaults.set(data, forKey: preferencesKey)
        self.environment = environment
        self.localAddress = local.origin
        self.remoteAddress = remote.origin
        revision += 1
    }

    func removeRemoteToken() throws {
        try tokens.delete(origin: AnalysisEndpoint(address: remoteAddress, environment: .remote).origin)
        revision += 1
    }

    func makeClient(session: URLSession? = nil) throws -> AgentClient {
        let endpoint = try AnalysisEndpoint(address: currentAddress, environment: environment)
        let token: String?
        if environment == .remote {
            token = try requiredToken(origin: endpoint.origin)
            try Self.validateToken(token!)
        } else { token = nil }
        return AgentClient(session: session ?? AgentClient.analysisSession, baseURL: endpoint.url, accessToken: token)
    }

    private func requiredToken(origin: String) throws -> String {
        guard let token = try tokens.read(origin: origin) else {
            throw AgentClientError.configuration("请在服务设置中填写此远端地址的访问令牌（不是阿里云 AK 或百炼密钥）。")
        }
        return token
    }
    private static func validateToken(_ token: String) throws {
        guard (32...256).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw AgentClientError.configuration("访问令牌需为 32–256 个可见 ASCII 字符，不能含空格或换行。")
        }
    }
}
