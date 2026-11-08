import XCTest
import Foundation
import Network
@testable import TimeWeaveCore

final class AgentClientTests: XCTestCase, @unchecked Sendable {
    func snapshot() throws -> AnalysisSnapshot {
        try AnalysisSnapshotBuilder.build(ledger: TimeLedger(), period: 7)
    }
    func client(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) -> AgentClient {
        StubURLProtocol.set(handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AgentClient(session: URLSession(configuration: config))
    }
    func testRequestUsesMinimalContractAndDecodesAnswer() async throws {
        let client = client { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8787/v1/analysis")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
            }
            let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(object["question"] as? String, "分析")
            XCTAssertEqual(object["schema_version"] as? Int, 1)
            let snapshot = object["snapshot"] as! [String: Any]
            XCTAssertEqual(Set(snapshot.keys), ["range", "total_minutes", "categories", "days"])
            return (200, Data(#"{"schema_version":1,"run_id":"run-test","answer":"记录了 60 分钟"}"#.utf8))
        }
        let response = try await client.analyze(question: "分析", snapshot: snapshot())
        XCTAssertEqual(response.answer, "记录了 60 分钟")
        XCTAssertEqual(response.runID, "run-test")
    }

    func testInvalidResponsesAndTransportErrorsAreReadable() async throws {
        for (status, body) in [(200, "broken"), (200, #"{"schema_version":2,"run_id":"r","answer":"答案"}"#), (200, #"{"schema_version":1,"run_id":"r","answer":" "}"#), (500, "HTML upstream secret")] {
            let client = client { _ in (status, Data(body.utf8)) }
            do { _ = try await client.analyze(question: "分析", snapshot: snapshot()); XCTFail("accepted invalid response") }
            catch { XCTAssertFalse(error.localizedDescription.contains("secret")); XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        for code in [URLError.cannotConnectToHost, .timedOut] {
            let client = client { _ in throw URLError(code) }
            do { _ = try await client.analyze(question: "分析", snapshot: snapshot()); XCTFail("ignored transport failure") }
            catch let error as AgentClientError { XCTAssertTrue(error.retryable) }
        }
    }

    @MainActor
    func testPairingSendsOnlyTheCodeAndReusesTheCredentialAfterReload() async throws {
        let name = "TimeWeave.PairingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let vault = MemoryAnalysisTokens()
        let settings = AnalysisServiceSettings(defaults: defaults, tokens: vault)
        let code = String(repeating: "A", count: 43)
        let token = String(repeating: "B", count: 42) + "A"
        let session = client { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/device-pairings/redeem")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any])
            XCTAssertEqual(Set(payload.keys), ["schema_version", "code"])
            XCTAssertEqual(payload["schema_version"] as? Int, 1)
            XCTAssertEqual(payload["code"] as? String, code)
            return (200, Data("{\"schema_version\":1,\"access_token\":\"\(token)\"}".utf8))
        }.session

        try await settings.pairRemote(qrPayload: "https://API.example.com:443/#timeweave-pair=\(code)", address: "https://api.example.com", session: session)

        let reloaded = AnalysisServiceSettings(defaults: defaults, tokens: vault)
        XCTAssertEqual(reloaded.environment, .remote)
        XCTAssertEqual(try reloaded.makeClient().baseURL.absoluteString, "https://api.example.com")
        XCTAssertEqual(try reloaded.makeClient().accessToken, token)
        let preferences = try XCTUnwrap(defaults.data(forKey: "analysis.service.v1"))
        XCTAssertFalse(String(decoding: preferences, as: UTF8.self).contains(token))
    }

    @MainActor
    func testInvalidPairingOriginOrCodeDoesNotSendARequest() async throws {
        let settings = AnalysisServiceSettings(tokens: MemoryAnalysisTokens())
        let code = String(repeating: "A", count: 43)
        let session = client { _ in
            XCTFail("Untrusted QR data must not reach the network")
            return (500, Data())
        }.session
        for qr in ["https://other.example.com/#timeweave-pair=\(code)",
                   "https://api.example.com/path#timeweave-pair=\(code)",
                   "https://api.example.com/#timeweave-pair=short",
                   "https://api.example.com/#timeweave-pair=\(String(repeating: "a", count: 43))"] {
            do {
                try await settings.pairRemote(qrPayload: qr, address: "https://api.example.com", session: session)
                XCTFail("Accepted invalid pairing QR")
            } catch let error as AgentClientError {
                guard case .configuration = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    @MainActor
    func testRejectedPairingPreservesTheExistingRemoteCredential() async throws {
        let name = "TimeWeave.PairingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AnalysisServiceSettings(defaults: defaults, tokens: MemoryAnalysisTokens())
        let token = String(repeating: "B", count: 42) + "A"
        let code = String(repeating: "A", count: 43)
        try settings.save(environment: .remote, localAddress: settings.localAddress, remoteAddress: "https://api.example.com", token: token)
        let revision = settings.revision
        let session = client { _ in
            (400, Data(#"{"schema_version":1,"error":{"code":"invalid_pairing","message":"配对码无效或已过期。","retryable":false}}"#.utf8))
        }.session

        do {
            try await settings.pairRemote(qrPayload: "https://api.example.com/#timeweave-pair=\(code)", address: "https://api.example.com", session: session)
            XCTFail("Accepted a rejected pairing")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .server(code: "invalid_pairing", message: "配对码无效或已过期。", retryable: false, runID: nil))
        }
        XCTAssertEqual(settings.revision, revision)
        XCTAssertEqual(try settings.makeClient().accessToken, token)
    }

    func testServerErrorPreservesRunIDAndRetryPolicy() async throws {
        let client = client { _ in (400, Data(#"{"schema_version":1,"run_id":"run-bad","error":{"code":"invalid_request","message":"快照无效","retryable":false}}"#.utf8)) }
        do { _ = try await client.analyze(question: "分析", snapshot: snapshot()); XCTFail("accepted 400") }
        catch let error as AgentClientError {
            XCTAssertFalse(error.retryable)
            XCTAssertEqual(error.runID, "run-bad")
            XCTAssertEqual(error.localizedDescription, "快照无效")
        }
    }

    @MainActor
    func testSelectedRemoteAddsBearerWhileLocalNeverUsesRemoteToken() async throws {
        let name = "TimeWeave.RequestTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AnalysisServiceSettings(defaults: defaults, tokens: MemoryAnalysisTokens())
        let token = String(repeating: "b", count: 64)
        try settings.save(environment: .remote, localAddress: settings.localAddress, remoteAddress: "https://api.example.com", token: token)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        StubURLProtocol.set { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/analysis")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
            return (200, Data(#"{"schema_version":1,"run_id":"remote","answer":"远端"}"#.utf8))
        }
        let remote = try settings.makeClient(session: session)
        let answer = try await remote.analyze(question: "分析", snapshot: snapshot())
        XCTAssertEqual(answer.runID, "remote")
        try settings.save(environment: .local, localAddress: settings.localAddress, remoteAddress: settings.remoteAddress, token: nil)
        StubURLProtocol.set { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data(#"{"schema_version":1,"run_id":"local","answer":"本地"}"#.utf8))
        }
        _ = try await settings.makeClient(session: session).analyze(question: "分析", snapshot: snapshot())
    }

    func testClientRefusesRedirectRatherThanResendingSensitivePOST() async throws {
        let server = try AnalysisRedirectServer()
        defer { server.stop() }
        let port = try await server.start()
        let client = AgentClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, accessToken: String(repeating: "x", count: 64))
        do {
            _ = try await client.analyze(question: "不应被转发", snapshot: snapshot())
            XCTFail("followed the redirect and leaked the analysis to /leak")
        } catch let error as AgentClientError { XCTAssertEqual(error, .invalidResponse) }
    }

    func testConversationClientDiscoversCapabilitiesAndCreatesConversation() async throws {
        let token = String(repeating: "r", count: 32)
        let client = AgentClient(session: stubSession(), baseURL: URL(string: "https://agent.example.com")!, accessToken: token)
        StubURLProtocol.set { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/capabilities"):
                return (200, Data(#"{"schema_version":1,"conversations":true,"memories":true}"#.utf8))
            case ("POST", "/v1/conversations"):
                XCTAssertEqual(try requestBodyData(request), Data("{}".utf8))
                return (201, Data(#"{"conversation_id":"conv-1","principal_id":"remote","title":"新对话","revision":1,"messages":[],"turns":[],"created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:00Z"}"#.utf8))
            default:
                XCTFail("unexpected request \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
                return (500, Data())
            }
        }

        let capabilities = try await client.capabilities()
        XCTAssertTrue(capabilities.conversations)
        XCTAssertTrue(capabilities.memories)
        let conversation = try await client.createConversation()
        XCTAssertEqual(conversation.id, "conv-1")
        XCTAssertEqual(conversation.messages, [])
    }

    func testConversationClientStreamsTurnToCompletionWithoutPolling() async throws {
        let client = AgentClient(session: stubSession())
        let postCount = LockedCounter()
        let eventCount = LockedCounter()
        let pollCount = LockedCounter()
        StubURLProtocol.set { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/conversations/conv-1/turns"):
                postCount.increment()
                return (202, Data(#"{"turn_id":"turn-1","conversation_id":"conv-1","message_id":"message-stable","thread_id":"thread-turn-1","question":"继续分析","period_days":7,"status":"accepted","created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:00Z"}"#.utf8))
            case ("GET", "/v1/conversations/conv-1/turns/turn-1/events"):
                eventCount.increment()
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
                let body = """
                event: turn
                data: {"turn_id":"turn-1","conversation_id":"conv-1","message_id":"message-stable","thread_id":"thread-turn-1","question":"继续分析","period_days":7,"status":"running","created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:00Z"}

                event: turn
                data: {"turn_id":"turn-1","conversation_id":"conv-1","message_id":"message-stable","thread_id":"thread-turn-1","question":"继续分析","period_days":7,"status":"completed","run_id":"run-1","answer":"工作 60 分钟","memory_changes":[],"created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:01Z"}

                """
                return (200, Data(body.utf8))
            case ("GET", "/v1/conversations/conv-1/turns/turn-1"):
                pollCount.increment()
                return (500, Data())
            default:
                XCTFail("unexpected request \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
                return (500, Data())
            }
        }

        let turn: ConversationTurn
        do {
            turn = try await client.sendMessage(conversationID: "conv-1", messageID: "message-stable", question: "继续分析", periodDays: 7, snapshot: snapshot())
        } catch {
            XCTFail("SSE failed with \(error); posts=\(postCount.value) events=\(eventCount.value) polls=\(pollCount.value)")
            return
        }

        XCTAssertEqual(postCount.value, 1)
        XCTAssertEqual(eventCount.value, 1)
        XCTAssertEqual(pollCount.value, 0)
        XCTAssertEqual(turn.status, .completed)
        XCTAssertEqual(turn.answer, "工作 60 分钟")
    }

    func testConversationClientFallsBackToPollingWithoutResubmitting() async throws {
        let client = AgentClient(session: stubSession())
        let postCount = LockedCounter()
        let eventCount = LockedCounter()
        let getCount = LockedCounter()
        StubURLProtocol.set { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/conversations/conv-1/turns"):
                postCount.increment()
                let object = try JSONSerialization.jsonObject(with: requestBodyData(request)) as! [String: Any]
                XCTAssertEqual(object["schema_version"] as? Int, 1)
                XCTAssertEqual(object["message_id"] as? String, "message-stable")
                XCTAssertEqual(object["question"] as? String, "继续分析")
                XCTAssertEqual(object["period_days"] as? Int, 7)
                XCTAssertNotNil(object["snapshot"] as? [String: Any])
                return (202, Data(#"{"turn_id":"turn-1","conversation_id":"conv-1","message_id":"message-stable","thread_id":"thread-turn-1","question":"继续分析","period_days":7,"status":"accepted","created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:00Z"}"#.utf8))
            case ("GET", "/v1/conversations/conv-1/turns/turn-1/events"):
                eventCount.increment()
                return (404, Data(#"{"schema_version":1,"error":{"code":"not_found","message":"接口不存在。","retryable":false}}"#.utf8))
            case ("GET", "/v1/conversations/conv-1/turns/turn-1"):
                getCount.increment()
                return (200, Data(#"{"turn_id":"turn-1","conversation_id":"conv-1","message_id":"message-stable","thread_id":"thread-turn-1","question":"继续分析","period_days":7,"status":"completed","run_id":"run-1","answer":"工作 60 分钟","memory_changes":[],"created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:01Z"}"#.utf8))
            default:
                XCTFail("unexpected request \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
                return (500, Data())
            }
        }

        let turn = try await client.sendMessage(conversationID: "conv-1", messageID: "message-stable", question: "继续分析", periodDays: 7, snapshot: snapshot())

        XCTAssertEqual(postCount.value, 1)
        XCTAssertEqual(eventCount.value, 1)
        XCTAssertEqual(getCount.value, 1)
        XCTAssertEqual(turn.status, .completed)
        XCTAssertEqual(turn.answer, "工作 60 分钟")
        XCTAssertEqual(turn.runID, "run-1")
    }

    func testConversationClientRejectsOversizedMultiLineEventAndRecoversWithGET() async throws {
        let client = AgentClient(session: stubSession())
        let pollCount = LockedCounter()
        let terminal = #"{"turn_id":"turn-1","conversation_id":"conv-1","message_id":"message-stable","thread_id":"thread-turn-1","question":"继续分析","period_days":7,"status":"completed","run_id":"run-sse","answer":"不应接受的超大事件","memory_changes":[],"created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:01Z"}"#
        let oneMiBOfJSONWhitespace = String(repeating: "\t", count: 1024 * 1024)
        let oversizedEvent = "event: turn\ndata: \(terminal)\n" + String(repeating: "data:\(oneMiBOfJSONWhitespace)\n", count: 5) + "\n"
        StubURLProtocol.set { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/conversations/conv-1/turns"):
                return (202, Data(#"{"turn_id":"turn-1","conversation_id":"conv-1","message_id":"message-stable","thread_id":"thread-turn-1","question":"继续分析","period_days":7,"status":"accepted","created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:00Z"}"#.utf8))
            case ("GET", "/v1/conversations/conv-1/turns/turn-1/events"):
                return (200, Data(oversizedEvent.utf8))
            case ("GET", "/v1/conversations/conv-1/turns/turn-1"):
                pollCount.increment()
                return (200, Data(#"{"turn_id":"turn-1","conversation_id":"conv-1","message_id":"message-stable","thread_id":"thread-turn-1","question":"继续分析","period_days":7,"status":"completed","run_id":"run-get","answer":"GET 恢复答案","memory_changes":[],"created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:02Z"}"#.utf8))
            default:
                XCTFail("unexpected request \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return (500, Data())
            }
        }

        let turn = try await client.sendMessage(conversationID: "conv-1", messageID: "message-stable", question: "继续分析", periodDays: 7, snapshot: snapshot())

        XCTAssertEqual(pollCount.value, 1)
        XCTAssertEqual(turn.runID, "run-get")
        XCTAssertEqual(turn.answer, "GET 恢复答案")
    }

    func testConversationClientRejectsMalformedTerminalTurn() async throws {
        let client = AgentClient(session: stubSession())
        StubURLProtocol.set { request in
            if request.httpMethod == "POST" {
                return (202, Data(#"{"turn_id":"turn-1","conversation_id":"conv-1","message_id":"message-1","thread_id":"thread-turn-1","question":"分析","period_days":7,"status":"accepted","created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:00Z"}"#.utf8))
            }
            return (200, Data(#"{"turn_id":"turn-1","conversation_id":"conv-1","message_id":"message-1","thread_id":"thread-turn-1","question":"分析","period_days":7,"status":"completed","answer":" ","created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:01Z"}"#.utf8))
        }

        do {
            _ = try await client.sendMessage(conversationID: "conv-1", messageID: "message-1", question: "分析", periodDays: 7, snapshot: snapshot())
            XCTFail("accepted malformed terminal turn")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testMemoryControlResourcesUseTypedContracts() async throws {
        let client = AgentClient(session: stubSession())
        StubURLProtocol.set { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/memory-settings"):
                return (200, Data(#"{"proactive_enabled":true}"#.utf8))
            case ("PUT", "/v1/memory-settings"):
                let object = try JSONSerialization.jsonObject(with: requestBodyData(request)) as! [String: Any]
                XCTAssertEqual(object["proactive_enabled"] as? Bool, false)
                return (200, Data(#"{"proactive_enabled":false}"#.utf8))
            case ("PATCH", "/v1/memories/memory-1"):
                return (200, Data(#"{"memory_id":"memory-1","kind":"goal","text":"每周复盘","status":"active","sensitivity":"normal","origin":"user_edited","source_conversation_id":"conv-1","source_message_id":"message-1","created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:01Z"}"#.utf8))
            case ("DELETE", "/v1/memories"):
                return (204, Data())
            default:
                XCTFail("unexpected request \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return (500, Data())
            }
        }

        let initial = try await client.memoryPreferences()
        let disabled = try await client.setProactiveMemory(false)
        let edited = try await client.editMemory(id: "memory-1", kind: .goal, text: "每周复盘")
        XCTAssertTrue(initial.proactiveEnabled)
        XCTAssertFalse(disabled.proactiveEnabled)
        XCTAssertEqual(edited.text, "每周复盘")
        try await client.clearMemories()
    }

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(buffer, count: count)
        }
    }
    return body
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func increment() { lock.lock(); stored += 1; lock.unlock() }
}

/// Real loopback HTTP boundary: following the 307 returns a valid but wrong answer.
private final class AnalysisRedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TimeWeave.RedirectTest")
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                guard let self, let data, let port = self.listener.port else { connection.cancel(); return }
                let firstLine = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")[0]
                let response: String
                if firstLine.contains(" /v1/analysis ") {
                    response = "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(port.rawValue)/leak\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                } else {
                    let answer = #"{"schema_version":1,"run_id":"leak","answer":"redirect followed"}"#
                    response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(answer.utf8.count)\r\nConnection: close\r\n\r\n" + answer
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: self.listener.port!.rawValue)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    static func set(_ value: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { lock.lock(); defer { lock.unlock() }; handler = value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            let (status, body) = try handler!(request)
            let contentType = request.value(forHTTPHeaderField: "Accept") == "text/event-stream" ? "text/event-stream" : "application/json"
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
