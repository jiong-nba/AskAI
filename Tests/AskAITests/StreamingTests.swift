import Foundation
import Testing
@testable import AskAI

/// A fake streaming endpoint on top of URLProtocol, so `askLLM` is exercised through the real
/// URLSession byte stream. The URL path selects the script the "server" follows.
private final class StreamingAPI: URLProtocol {
    private enum Event {
        case chunk(String)
        case fail(Int)   // URLError code
    }

    private static let content = #"data: {"choices":[{"delta":{"content":"%@"}}]}"#
    private static let stop = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#

    private static func script(for path: String) -> [Event] {
        let hello = chunk(Self.content, "hel")
        let lo = chunk(Self.content, "lo")
        let done = Event.chunk("data: [DONE]\n\n")
        switch path {
        case "/clean":        return [hello, lo, .chunk(stop + "\n\n"), done]
        case "/noisy-tail":   return [hello, lo, .chunk(stop + "\n\n"), .fail(URLError.networkConnectionLost.rawValue)]
        case "/keepalive":    return [.chunk("data: ping\n\n"), hello, .chunk("data: [PING]\n\n"), lo, .chunk(stop + "\n\n"), done]
        case "/no-done-mark": return [hello, lo, .chunk(stop + "\n\n")]
        case "/cut":          return [hello, .fail(URLError.networkConnectionLost.rawValue)]
        case "/reasoning":
            let think = Event.chunk(#"data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}"# + "\n\n")
            return [think, hello, lo, .chunk(stop + "\n\n"), done]
        default:              return []
        }
    }

    private static func chunk(_ format: String, _ text: String) -> Event {
        .chunk(String(format: format, text) + "\n\n")
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let client = self.client
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for event in Self.script(for: url.path) {
            // A real transport delivers a chunk and a later failure apart in time. URLProtocol would
            // deliver them back to back, and URLSession then drops bytes the consumer has not drained.
            Thread.sleep(forTimeInterval: 0.02)
            switch event {
            case .chunk(let text): client?.urlProtocol(self, didLoad: Data(text.utf8))
            case .fail(let code): client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct StreamingFixture {
    let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingAPI.self]
        session = URLSession(configuration: config)
    }

    func connection(_ path: String) -> ConnectionSettings {
        ConnectionSettings(url: URL(string: "https://fixture.invalid\(path)")!,
                           model: "fixture-model", apiKey: "fixture-key", summaryLimit: 16_000)
    }
}

struct StreamingTests {
    @Test func completionIsDecidedByTheServerNotByHowTheConnectionEnds() async throws {
        let fixture = StreamingFixture()
        defer { fixture.session.invalidateAndCancel() }
        let mode = historyMode("explain")
        // A transport error after finish_reason, missing [DONE], and keepalive lines must not
        // turn a complete answer into a failure.
        for path in ["/clean", "/noisy-tail", "/keepalive", "/no-done-mark"] {
            let answer = try await askLLM(QueryInput(preview: "q"), mode: mode, connection: fixture.connection(path),
                                          session: fixture.session, onDelta: { _ in })
            #expect(answer == "hello", "script \(path)")
        }
    }

    @Test func aStreamCutBeforeCompletionStillFails() async throws {
        let fixture = StreamingFixture()
        defer { fixture.session.invalidateAndCancel() }
        let updates = Recorder<String>()
        await #expect(throws: URLError.self) {
            _ = try await askLLM(QueryInput(preview: "q"), mode: historyMode("explain"),
                                 connection: fixture.connection("/cut"), session: fixture.session,
                                 onDelta: { updates.append($0) })
        }
        #expect(updates.values == ["hel"])
    }

    @Test func reasoningIsStreamedSeparatelyOverHTTP() async throws {
        let fixture = StreamingFixture()
        defer { fixture.session.invalidateAndCancel() }
        let answers = Recorder<String>()
        let reasoning = Recorder<String>()
        let result = try await askLLM(QueryInput(preview: "q"), mode: historyMode("explain"),
                                      connection: fixture.connection("/reasoning"), session: fixture.session,
                                      onDelta: { answers.append($0) }, onReasoning: { reasoning.append($0) })
        // The return value and the content deltas carry the answer only; reasoning has its own channel.
        #expect(result == "hello")
        #expect(answers.values == ["hel", "hello"])
        #expect(reasoning.values == ["thinking"])
    }
}
