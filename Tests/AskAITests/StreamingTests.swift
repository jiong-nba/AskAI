import Foundation
import Testing
@testable import AskAI

/// A fake streaming endpoint on top of URLProtocol, so `askLLM` is exercised through the real
/// URLSession byte stream. The URL path selects the script the "server" follows.
///
/// Nothing here depends on timing. URLProtocol hands bytes and errors to URLSession back to back,
/// and URLSession then drops bytes the consumer has not read yet, so the fixture never reports an
/// error before it *knows* where the consumer is:
///   - `/noisy-tail` waits for the consumer to give up reading (it cancels the task as soon as it
///     stops) and reports the connection error only if that never happens;
///   - `/cut` waits for the consumer's first delta before reporting the connection error.
/// 可变状态（`stopRequested`）在条件锁里；URLProtocol 的 client 回调本来就允许从任意线程调用。
private final class StreamingAPI: URLProtocol, @unchecked Sendable {
    private enum Event {
        case chunk(String)
        case fail   // URLError.networkConnectionLost, sent once the consumer is known to be done
    }

    private static let content = #"data: {"choices":[{"delta":{"content":"%@"}}]}"#
    private static let stop = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#

    /// Set by the `/cut` test: signalled from its `onDelta`, i.e. once the first piece was read.
    static let firstPieceRead = Locked<Cue?>(nil)

    private static func script(for path: String) -> [Event] {
        let hello = chunk(Self.content, "hel")
        let lo = chunk(Self.content, "lo")
        let done = Event.chunk("data: [DONE]\n\n")
        switch path {
        case "/clean":        return [hello, lo, .chunk(stop + "\n\n"), done]
        case "/noisy-tail":   return [hello, lo, .chunk(stop + "\n\n"), .fail]
        case "/keepalive":    return [.chunk("data: ping\n\n"), hello, .chunk("data: [PING]\n\n"), lo, .chunk(stop + "\n\n"), done]
        case "/no-done-mark": return [hello, lo, .chunk(stop + "\n\n")]
        case "/cut":          return [hello, .fail]
        case "/reasoning":
            let think = Event.chunk(#"data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}"# + "\n\n")
            return [think, hello, lo, .chunk(stop + "\n\n"), done]
        default:              return []
        }
    }

    private static func chunk(_ format: String, _ text: String) -> Event {
        .chunk(String(format: format, text) + "\n\n")
    }

    /// How long the fixture waits for a signal from the consumer. It only matters when the app
    /// misbehaves: the wait then runs out and the connection error is delivered as planned.
    private static let patience: TimeInterval = 5

    private let cancelled = NSCondition()
    private var stopRequested = false
    private let scriptQueue = DispatchQueue(label: "AskAI.tests.StreamingAPI")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // The script runs on its own queue: `stopLoading` must stay able to run while it waits.
        scriptQueue.async { self.performScript() }
    }

    private func performScript() {
        guard let client, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for event in Self.script(for: url.path) {
            switch event {
            case .chunk(let text):
                client.urlProtocol(self, didLoad: Data(text.utf8))
            case .fail:
                if url.path == "/noisy-tail" {
                    // The consumer cancels the task once it stops reading. If it does, the load is over
                    // and there is nothing to report. If it never does, the connection breaks as planned,
                    // and the answer then has to be reported as failed.
                    if waitForCancellation() { return }
                } else {
                    // `/cut`: break the connection only once the first piece is known to have been read.
                    _ = waitForFirstPiece()
                }
                client.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        cancelled.lock()
        stopRequested = true
        cancelled.signal()
        cancelled.unlock()
    }

    /// True once the consumer cancelled the task, which `askLLM` does as soon as it stops reading.
    private func waitForCancellation() -> Bool {
        let deadline = Date().addingTimeInterval(Self.patience)
        cancelled.lock(); defer { cancelled.unlock() }
        while !stopRequested && cancelled.wait(until: deadline) { }
        return stopRequested
    }

    /// True once the `/cut` test's `onDelta` has been called.
    private func waitForFirstPiece() -> Bool {
        Self.firstPieceRead.get()?.wait(seconds: Self.patience) ?? false
    }
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
    // The server, not the way the connection ends, decides whether an answer is complete: a
    // connection that breaks after `finish_reason`, or never sends `[DONE]`, must not fail it.
    @Test func completionIsDecidedByTheServerNotByHowTheConnectionEnds() async throws {
        let fixture = StreamingFixture()
        defer { fixture.session.invalidateAndCancel() }
        let mode = historyMode("explain")
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
        let firstPiece = Cue()
        StreamingAPI.firstPieceRead.set(firstPiece)
        defer { StreamingAPI.firstPieceRead.set(nil) }
        var thrown: Error?
        do {
            _ = try await askLLM(QueryInput(preview: "q"), mode: historyMode("explain"),
                                 connection: fixture.connection("/cut"), session: fixture.session,
                                 onDelta: { updates.append($0); firstPiece.signal() })
        } catch {
            thrown = error
        }
        // The broken connection itself, not some other URLError such as a request timeout.
        #expect((thrown as? URLError)?.code == .networkConnectionLost)
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
