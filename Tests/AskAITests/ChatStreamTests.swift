import Testing
@testable import AskAI

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
            var updates: [String] = []
            do {
                _ = try await readChatStream(lines([content] + ending)) { updates.append($0) }
                Issue.record("Interrupted stream reported success with ending \(ending)")
            } catch {
                #expect(updates == ["hello"])
            }
        }
    }
}
