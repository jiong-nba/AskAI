import AppKit
import Foundation
import Testing
@testable import AskAI

// An OpenAI-compatible echo response exposes exactly what URLSession received.
private final class EchoAPI: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    guard n >= 0 else { throw URLError(.cannotDecodeRawData) }
                    if n == 0 { break }
                    data.append(contentsOf: buffer.prefix(n))
                }
            }
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: String]])
            let content = try #require(messages.last?["content"])
            let url = try #require(request.url)
            #expect(url.host == "fixture.invalid")
            #expect(body["model"] as? String == "fixture-model")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let reply = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func echoSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [EchoAPI.self]
    return URLSession(configuration: config)
}

struct QueryWorkflowTests {
    @Test func previewAndFullSummaryReachTheWire() async throws {
        let text = String(repeating: "甲", count: 2995) + "结论：乙。"
        let mode = historyMode("summarize")
        let config = ConnectionSettings(url: URL(string: "https://fixture.invalid/chat")!,
                                        model: "fixture-model", apiKey: "fixture-key", summaryLimit: 3000)
        let session = echoSession()
        defer { session.invalidateAndCancel() }
        let preview = QueryInput(preview: text)
        #expect(preview.sent == 2000)
        let short = try await askLLM(preview, mode: mode, connection: config, session: session)
        #expect(short.hasPrefix(String(repeating: "甲", count: 2000)))
        #expect(!short.contains("结论"))
        let full = try QueryInput(fullSummary: text, limit: config.summaryLimit)
        #expect(full.sent == 3000)
        #expect(try await askLLM(full, mode: mode, connection: config, session: session) == text)
        #expect(throws: AskError.self) { try QueryInput(fullSummary: text, limit: 2999) }
        let exact = String(repeating: "👩🏽‍💻", count: 2000)
        #expect(QueryInput(preview: exact).message == exact)
    }

    @Test func testDraftWithoutSavingAndApplyWithoutRestart() async throws {
        let suite = "AskAI-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("old-model", forKey: "model")
        defaults.set("old-key", forKey: "apiKey")
        var draft = ConnectionDraft(defaults: defaults)
        draft.endpoint = "https://fixture.invalid/v1/chat/completions"
        draft.model = "fixture-model"
        draft.savedKey = "fixture-key"
        draft.limit = "8000"
        let session = echoSession()
        defer { session.invalidateAndCancel() }
        try await draft.testConnection(environmentKey: nil, session: session)
        #expect(defaults.string(forKey: "model") == "old-model")
        try draft.save(to: defaults, environmentKey: nil)
        let live = ConnectionSettings.current(defaults: defaults, environmentKey: nil)
        #expect(live.url.absoluteString == draft.endpoint && live.model == draft.model)
        #expect(live.apiKey == draft.savedKey && live.summaryLimit == 8000)
        draft.savedKey = "unused"
        try draft.save(to: defaults, environmentKey: "env-key")
        #expect(defaults.string(forKey: "apiKey") == "fixture-key")
        #expect(ConnectionSettings.current(defaults: defaults, environmentKey: "env-key").apiKey == "env-key")
        draft.endpoint = "missing-host"
        #expect(throws: AskError.self) { try draft.save(to: defaults, environmentKey: nil) }
        #expect(defaults.string(forKey: "baseURL") == live.url.absoluteString)
    }

    @Test @MainActor func directSelectionAndCopyFallback() async throws {
        var copies = 0
        let copy: (pid_t) async -> String? = { _ in copies += 1; return "fallback" }
        let direct = try await selectedText(focusedPID: { 42 }, readAX: { _ in "selected" }, copy: copy)
        #expect(direct == "selected" && copies == 0)
        let fallback = try await selectedText(focusedPID: { 42 }, readAX: { _ in nil }, copy: copy)
        #expect(fallback == "fallback" && copies == 1)
        var focus: pid_t = 42
        do {
            _ = try await selectedText(focusedPID: { defer { focus += 1 }; return focus },
                                       readAX: { _ in "old selection" }, copy: copy)
            Issue.record("A changed foreground application must abandon capture")
        } catch is CancellationError {}
        #expect(copies == 1)
    }

    @Test @MainActor func clipboardChangesAndTimeout() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let items = [NSPasteboardItem(), NSPasteboardItem()]
        items[0].setString("rich", forType: .string)
        items[0].setData(Data([1, 2, 3]), forType: .rtf)
        items[1].setString("second", forType: .string)
        board.writeObjects(items)
        let generation = board.changeCount
        let none = try await copiedSelection(from: board, timeout: .milliseconds(20)) {}
        #expect(none == nil && board.changeCount == generation)
        let selection = try await copiedSelection(from: board) {
            Task { @MainActor in
                board.clearContents()
                board.setString("  selection\n", forType: .string)
            }
        }
        #expect(selection == "selection")
        #expect(board.pasteboardItems?.count == 2)
        #expect(board.pasteboardItems?.first?.data(forType: .rtf) == Data([1, 2, 3]))
        #expect(board.pasteboardItems?.last?.string(forType: .string) == "second")
    }
}
