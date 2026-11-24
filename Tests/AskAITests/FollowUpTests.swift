import AppKit
import Foundation
import Testing
@testable import AskAI

// Serialized: these panels share NSApplication, and several tests wait for a stream to reach a state.
@Suite(.serialized)
struct FollowUpTests {
    @MainActor
    private func views(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views(in:)) }

    @MainActor
    private func answerView(in panel: ResultPanel) throws -> NSTextView {
        let content = try #require(panel.contentView)
        return try #require(views(in: content).compactMap { $0 as? NSTextView }.first)
    }

    @MainActor
    private func button(_ title: String, in panel: ResultPanel) throws -> NSButton {
        let content = try #require(panel.contentView)
        return try #require(views(in: content).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    @MainActor
    private func questionField(in panel: ResultPanel) throws -> NSTextField {
        let content = try #require(panel.contentView)
        return try #require(views(in: content).compactMap { $0 as? NSTextField }.first { $0.isEditable })
    }

    // A follow-up is sent with the earlier turns as context, is shown with its question, and is saved
    // together with that question.
    @Test @MainActor func followUpsCarryTheEarlierTurnsAsContext() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var sent: [(message: String, context: [ChatTurn])] = []
        let (saved, signalSave) = AsyncStream<HistoryEntry>.makeStream()
        let explain = historyMode("explain")
        let panel = ResultPanel(source: "idempotency", pasteboard: board, send: { input, _, _, context, delta, _ in
            sent.append((input.message, context))
            let answer = "answer \(sent.count)"
            await delta?(answer)
            return answer
        }, save: { mode, source, answer, count, question in
            signalSave.yield(HistoryEntry(time: Date(), mode: mode, source: source, answer: answer,
                                          sentCharacters: count, question: question))
        })
        defer { panel.close(); signalSave.finish() }
        await panel.request(connection: fixtureConnection, mode: explain)?.value
        await panel.request(connection: fixtureConnection, mode: explain, question: "and why?")?.value
        await panel.request(connection: fixtureConnection, mode: explain, question: "really?")?.value

        let first = ChatTurn(question: "idempotency", answer: "answer 1", message: "idempotency", isFollowUp: false)
        let second = ChatTurn(question: "and why?", answer: "answer 2", message: "and why?", isFollowUp: true)
        #expect(sent.map(\.message) == ["idempotency", "and why?", "really?"])
        #expect(sent.map(\.context) == [[], [first], [first, second]])
        #expect(try answerView(in: panel).string ==
            "answer 1\n\n————\n\n❓ and why?\n\nanswer 2\n\n————\n\n❓ really?\n\nanswer 3")

        var history = saved.makeAsyncIterator()
        let opening = try #require(await history.next())
        #expect(opening.question == nil && opening.sentCharacters == 11)
        let followUp = try #require(await history.next())
        #expect(followUp.source == "idempotency" && followUp.question == "and why?")
        #expect(followUp.answer == "answer 2" && followUp.sentCharacters == nil)
    }

    // Stop keeps what has already arrived on screen; Retry asks the same thing again.
    @Test @MainActor func stopKeepsThePartialAnswerAndRetryAsksAgain() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var asked: [String] = []
        let (partialShown, signalPartial) = AsyncStream<Void>.makeStream()
        let panel = ResultPanel(source: "idempotency", pasteboard: board, send: { input, _, _, _, delta, _ in
            asked.append(input.message)
            if asked.count == 1 {
                await delta?("partial answer")
                signalPartial.yield(())
                try await Task.sleep(for: .seconds(60))   // the panel stops this request
            }
            return "complete answer"
        }, save: { _, _, _, _, _ in })
        defer { panel.close(); signalPartial.finish() }
        panel.request(connection: fixtureConnection, mode: historyMode("explain"))
        var arrived = partialShown.makeAsyncIterator()
        _ = await arrived.next()
        #expect(try answerView(in: panel).string == "partial answer")

        let stop = try button(L("停止", "Stop"), in: panel)
        #expect(stop.sendAction(stop.action, to: stop.target))
        #expect(try answerView(in: panel).string.hasPrefix("partial answer"))
        #expect(try answerView(in: panel).string.contains(L("已停止生成", "Generation stopped")))

        let retry = try button(L("重试", "Retry"), in: panel)
        #expect(retry.sendAction(retry.action, to: retry.target))
        var waited = 0
        while !(try answerView(in: panel).string.contains("complete answer")), waited < 1_000 {
            waited += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(asked == ["idempotency", "idempotency"])
        #expect(try answerView(in: panel).string == "complete answer")
    }

    @Test @MainActor func returnInTheFollowUpFieldSendsTheTrimmedQuestion() async throws {
        _ = NSApplication.shared
        var asked: [String] = []
        let panel = ResultPanel(source: "idempotency", pasteboard: .withUniqueName(), send: { input, _, _, _, delta, _ in
            asked.append(input.message)
            await delta?("answer \(asked.count)")
            return "answer \(asked.count)"
        }, save: { _, _, _, _, _ in })
        defer { panel.close() }
        await panel.request(connection: fixtureConnection, mode: historyMode("explain"))?.value

        let field = try questionField(in: panel)
        field.stringValue = "  what about X?  "
        #expect(panel.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        var waited = 0
        while asked.count < 2, waited < 1_000 {
            waited += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(asked == ["idempotency", "what about X?"])
        #expect(field.stringValue.isEmpty)
    }

    // ⌘C with a selection inside the follow-up field (or the answer) copies that selection, not the
    // whole conversation. (Checked on the decision itself: a real field editor needs an on-screen window.)
    @Test @MainActor func commandCYieldsWhileSomethingIsSelected() {
        func decides(modifiers: NSEvent.ModifierFlags = .command, answer: Int = 0, field: Int = 0) -> Bool {
            ResultPanel.commandCCopiesTheAnswer(modifiers: modifiers, characters: "c", answerSelection: answer,
                                                fieldSelection: field)
        }
        #expect(decides())
        #expect(decides(modifiers: [.command, .capsLock]))
        #expect(!decides(field: 5))
        #expect(!decides(answer: 2))
        #expect(!decides(modifiers: [.command, .shift]))
        #expect(!ResultPanel.commandCCopiesTheAnswer(modifiers: .command, characters: "v", answerSelection: 0,
                                                     fieldSelection: 0))
    }

    @Test @MainActor func transcriptListsEachFollowUpQuestionAboveItsAnswer() {
        let first = ChatTurn(question: "idempotency", answer: "a1", message: "idempotency", isFollowUp: false)
        let second = ChatTurn(question: "why?", answer: "a2", message: "why?", isFollowUp: true)
        #expect(ResultPanel.transcript(turns: [first, second], pending: nil, status: nil) == "a1\n\n————\n\n❓ why?\n\na2")
        let pending = ChatTurn(question: "really?", answer: "", message: "", isFollowUp: true)
        #expect(ResultPanel.transcript(turns: [first], pending: pending, status: nil)
            == "a1\n\n————\n\n❓ really?\n\n" + L("思考中…", "Thinking…"))
        #expect(ResultPanel.transcript(turns: [], pending: nil, status: "❌ boom") == "❌ boom")
        #expect(ResultPanel.transcript(turns: [first], pending: nil, status: "⏹ stopped") == "a1\n\n⏹ stopped")
    }

    // Switching modes after follow-ups goes back to the opening question instead of continuing the thread.
    @Test @MainActor func switchingModeRestartsFromTheOpeningQuestion() async throws {
        _ = NSApplication.shared
        var asked: [String] = []
        let panel = ResultPanel(source: "idempotency", pasteboard: .withUniqueName(), send: { input, _, _, context, delta, _ in
            asked.append("\(context.count) earlier turns: \(input.message)")
            await delta?("answer \(asked.count)")
            return "answer \(asked.count)"
        }, save: { _, _, _, _, _ in })
        defer { panel.close() }
        await panel.request(connection: fixtureConnection, mode: historyMode("explain"))?.value
        await panel.request(connection: fixtureConnection, mode: historyMode("explain"), question: "why?")?.value
        await panel.request(connection: fixtureConnection, mode: historyMode("translate"))?.value

        #expect(asked == ["0 earlier turns: idempotency", "1 earlier turns: why?", "0 earlier turns: idempotency"])
        #expect(try answerView(in: panel).string == "answer 3")
    }

    // History entries written before follow-ups existed have no "question"; new follow-up entries keep theirs.
    @Test func historyEntriesWithAndWithoutAQuestionDecode() throws {
        let legacy = Data(#"[{"time":0,"mode":"explain","source":"s","answer":"a"}]"#.utf8)
        let entry = try #require(JSONDecoder().decode([HistoryEntry].self, from: legacy).first)
        #expect(entry.question == nil && entry.source == "s")
        let data = try JSONEncoder().encode([HistoryEntry(time: Date(timeIntervalSince1970: 0), mode: "explain",
                                                          source: "s", answer: "a", question: "why?")])
        #expect(String(decoding: data, as: UTF8.self).contains(#""question":"why?""#))
    }
}

/// Answers with the conversation it received, one message per line: "role: content".
private final class TranscriptAPI: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    guard n > 0 else { break }
                    data.append(contentsOf: buffer.prefix(n))
                }
            }
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: String]])
            let transcript = messages.map { "\($0["role"] ?? "?"): \($0["content"] ?? "")" }.joined(separator: "|")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let reply = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": transcript]]]])
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

struct FollowUpRequestTests {
    // Earlier turns go between the system prompt and the new question, oldest first.
    @Test func askLLMSendsEarlierTurnsInOrder() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranscriptAPI.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let connection = ConnectionSettings(url: URL(string: "https://fixture.invalid/chat")!,
                                            model: "fixture-model", apiKey: "fixture-key", summaryLimit: 16_000)
        let first = ChatTurn(question: "q1", answer: "a1", message: "q1", isFollowUp: false)
        let second = ChatTurn(question: "q2", answer: "a2", message: "q2", isFollowUp: true)
        let answer = try await askLLM(QueryInput(preview: "q3"), mode: historyMode("explain"),
                                      connection: connection, context: [first, second], session: session)
        #expect(answer.hasPrefix("system: "))
        #expect(answer.hasSuffix("|user: q1|assistant: a1|user: q2|assistant: a2|user: q3"))
    }
}
