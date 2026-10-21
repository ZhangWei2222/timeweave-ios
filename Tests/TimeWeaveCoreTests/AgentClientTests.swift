import XCTest
import Foundation
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

    func testServerErrorPreservesRunIDAndRetryPolicy() async throws {
        let client = client { _ in (400, Data(#"{"schema_version":1,"run_id":"run-bad","error":{"code":"invalid_request","message":"快照无效","retryable":false}}"#.utf8)) }
        do { _ = try await client.analyze(question: "分析", snapshot: snapshot()); XCTFail("accepted 400") }
        catch let error as AgentClientError {
            XCTAssertFalse(error.retryable)
            XCTAssertEqual(error.runID, "run-bad")
            XCTAssertEqual(error.localizedDescription, "快照无效")
        }
    }
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
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
