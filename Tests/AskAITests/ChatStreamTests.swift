import Foundation
import Testing
@testable import AskAI

/// Yields its events, then the transport raises instead of ending cleanly.
private struct LinesThenFailure: AsyncSequence {
    typealias Element = String
    let events: [String]
    let failure: Error

    struct AsyncIterator: AsyncIteratorProtocol {
        let events: [String]
        let failure: Error
        var index = 0
        mutating func next() async throws -> String? {
            guard index < events.count else { throw failure }
            defer { index += 1 }
            return events[index]
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(events: events, failure: failure) }
}

struct ChatStreamTests {
    private let content = #"data: {"choices":[{"delta":{"content":"hello"}}]}"#
    private let stop = #"data: {"error":null,"choices":[{"delta":{},"finish_reason":"stop"}]}"#

    private func lines(_ events: [String]) -> AsyncStream<String> {
        AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    @Test func completionMarkers() async throws {
        for ending in [[stop], ["data: [DONE]"], [stop, "data: [DONE]"]] {
            let answer = try await readChatStream(lines([": heartbeat", content] + ending)) { _ in }
            #expect(answer == "hello")
        }
    }

    @Test func interruptedAnswerStillDeliversPartialText() async {
        let error = #"data: {"error":{"message":"upstream unavailable"}}"#
        let length = #"data: {"choices":[{"finish_reason":"length"}]}"#
        for ending in [[], [error, "data: [DONE]"], [length], ["data: {"]] {
            let updates = Recorder<String>()
            do {
                _ = try await readChatStream(lines([content] + ending)) { updates.append($0) }
                Issue.record("Interrupted stream reported success with ending \(ending)")
            } catch {
                #expect(updates.values == ["hello"])
            }
        }
    }

    // The server already confirmed completion; a noisy tail must not turn success into failure.
    @Test func connectionLossAfterFinishReasonKeepsTheCompleteAnswer() async throws {
        let stream = LinesThenFailure(events: [content, stop], failure: URLError(.networkConnectionLost))
        #expect(try await readChatStream(stream) { _ in } == "hello")
    }

    @Test func nonJSONDataLinesAreSkipped() async throws {
        // Keepalives and proxy-injected lines arrive as data: lines that are not JSON objects.
        let noise = ["data: ping", "data: [PING]", "data: {not json"]
        #expect(try await readChatStream(lines(noise + [content] + noise + [stop])) { _ in } == "hello")
    }

    @Test func reasoningStreamsSeparatelyFromContent() async throws {
        let think1 = #"data: {"choices":[{"delta":{"reasoning_content":"先想"}}]}"#
        let think2 = #"data: {"choices":[{"delta":{"reasoning_content":"想完"}}]}"#
        let reasoning = Recorder<String>()
        let updates = Recorder<String>()
        let answer = try await readChatStream(lines([think1, think2, content, stop])) {
            updates.append($0)
        } onReasoning: {
            reasoning.append($0)
        }
        // 返回值只有正文；思考过程经 onReasoning 增量推送，不混入 onDelta
        #expect(answer == "hello")
        #expect(reasoning.values == ["先想", "先想想完"])
        #expect(updates.values == ["hello"])
    }
}
