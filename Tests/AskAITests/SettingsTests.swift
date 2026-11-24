import AppKit
import Foundation
import Testing
@testable import AskAI

/// Answers with the Authorization header it received, so tests can see whether a key was sent.
private final class HeadersAPI: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let report = "auth=" + (request.value(forHTTPHeaderField: "Authorization") ?? "absent")
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil),
              let reply = try? JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": report]]]]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct SettingsTests {
    private func defaults() throws -> (UserDefaults, String) {
        let name = "AskAI.settings.tests-" + UUID().uuidString
        let suite = try #require(UserDefaults(suiteName: name))
        return (suite, name)
    }

    @Test func presetsMatchTheirOwnEndpointAndNothingElse() {
        #expect(ProviderPreset.matching(endpoint: "https://api.deepseek.com/chat/completions")?.name == "DeepSeek")
        #expect(ProviderPreset.matching(endpoint: "  http://localhost:11434/v1/chat/completions ")?.name == "Ollama (local)")
        #expect(ProviderPreset.matching(endpoint: "https://example.com/v1/chat/completions") == nil)
        #expect(ProviderPreset.matching(endpoint: "") == nil)
        #expect(Set(ProviderPreset.all.map(\.url)).count == ProviderPreset.all.count)
    }

    // Ollama, LM Studio and the like have no key: no placeholder key to type in, no header to send.
    @Test func localEndpointsWorkWithoutAKey() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeadersAPI.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let local = URL(string: "http://localhost:11434/v1/chat/completions")!
        func ask(_ connection: ConnectionSettings) async throws -> String {
            try await askLLM(QueryInput(preview: "q"), mode: historyMode("explain"),
                             connection: connection, session: session)
        }

        let keyless = ConnectionSettings(url: local, model: "m", apiKey: "", summaryLimit: 16_000)
        #expect(keyless.isLocal && keyless.isConfigured)
        #expect(try await ask(keyless) == "auth=absent")
        let keyed = ConnectionSettings(url: local, model: "m", apiKey: "k", summaryLimit: 16_000)
        #expect(try await ask(keyed) == "auth=Bearer k")
        let remote = ConnectionSettings(url: URL(string: "https://fixture.invalid/chat")!, model: "m", apiKey: "", summaryLimit: 16_000)
        #expect(!remote.isConfigured)
        await #expect(throws: AskError.self) { _ = try await ask(remote) }

        #expect(ConnectionSettings.isLocalEndpoint(URL(string: "http://127.0.0.1:1234/v1/chat/completions")!))
        #expect(ConnectionSettings.isLocalEndpoint(URL(string: "http://[::1]:11434/v1/chat/completions")!))
        // A name that merely starts with "localhost" is somebody else's machine.
        #expect(!ConnectionSettings.isLocalEndpoint(URL(string: "https://localhost.example.com/v1/chat/completions")!))
    }

    @Test func draftAcceptsALocalEndpointWithoutAKey() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var draft = ConnectionDraft(defaults: defaults)
        draft.savedKey = ""
        draft.model = "llama"
        draft.endpoint = "http://localhost:11434/v1/chat/completions"
        #expect(try draft.connection(environmentKey: nil).apiKey.isEmpty)
        draft.endpoint = "https://api.openai.com/v1/chat/completions"
        #expect(throws: AskError.self) { try draft.connection(environmentKey: nil) }
    }

    @Test func historyIsOffOnlyWhenSwitchedOff() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(historySavingEnabled(defaults: defaults))
        defaults.set(false, forKey: "saveHistory")
        #expect(!historySavingEnabled(defaults: defaults))
        defaults.set(true, forKey: "saveHistory")
        #expect(historySavingEnabled(defaults: defaults))
    }

    // The answer language follows the UI unless it is set on its own; each prompt asks for its language.
    @Test func answerLanguageFollowsTheUIUnlessSet() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AnswerLanguage.stored(defaults: defaults) == nil)
        #expect(AnswerLanguage.current(defaults: defaults) == (appIsChinese ? .chinese : .english))
        defaults.set("EN", forKey: "answerLanguage")
        #expect(AnswerLanguage.current(defaults: defaults) == .english)
        defaults.set("fr", forKey: "answerLanguage")
        #expect(AnswerLanguage.stored(defaults: defaults) == nil)

        let explain = historyMode("explain")
        #expect(explain.systemPrompt(language: .english).hasSuffix("Answer in English."))
        #expect(explain.systemPrompt(language: .chinese).contains("简体中文"))
        #expect(explain.systemPrompt(language: .english) != explain.systemPrompt(language: .chinese))
        // A single-prompt mode (the connection test, custom modes) reads the same in both languages.
        let probe = PromptMode(key: "test", title: "", system: "Reply with OK.")
        #expect(probe.systemPrompt(language: .chinese) == "Reply with OK." && probe.systemPrompt(language: .english) == "Reply with OK.")
    }

    @Test func settingsRoundTripThroughTheDraft() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var draft = ConnectionDraft(defaults: defaults)
        #expect(draft.answerLanguage == "" && draft.savesHistory)
        draft.savedKey = "fixture-key"
        draft.answerLanguage = "zh"
        draft.savesHistory = false
        try draft.save(to: defaults, environmentKey: nil)
        #expect(defaults.string(forKey: "answerLanguage") == "zh")
        #expect(defaults.object(forKey: "saveHistory") as? Bool == false)
        #expect(AnswerLanguage.current(defaults: defaults) == .chinese)
        let reloaded = ConnectionDraft(defaults: defaults)
        #expect(reloaded.answerLanguage == "zh" && reloaded.savesHistory == false)

        // An invalid value saves nothing at all.
        var invalid = reloaded
        invalid.answerLanguage = "fr"
        invalid.model = "changed-model"
        #expect(throws: AskError.self) { try invalid.save(to: defaults, environmentKey: nil) }
        #expect(defaults.string(forKey: "answerLanguage") == "zh" && defaults.string(forKey: "model") != "changed-model")

        // Back to "follow the UI" removes the key instead of storing an empty string.
        var back = reloaded
        back.answerLanguage = ""
        try back.save(to: defaults, environmentKey: nil)
        #expect(defaults.object(forKey: "answerLanguage") == nil)
    }
}
