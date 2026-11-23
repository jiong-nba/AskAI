import SwiftUI

struct AskError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

struct ConnectionSettings {
    static let defaultURL = URL(string: "https://api.deepseek.com/chat/completions")!
    static let defaultModel = "deepseek-chat"
    static let defaultSummaryLimit = 16_000
    let url: URL
    let model: String
    let apiKey: String
    let summaryLimit: Int

    // Keep the v1.1.1 interpretation of existing defaults. New form values are validated before saving.
    static func storedEndpoint(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    static func endpoint(_ text: String) -> URL? {
        guard let url = storedEndpoint(text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func current(defaults: UserDefaults = .standard,
                        environmentKey: String? = ProcessInfo.processInfo.environment["ASKAI_KEY"]) -> Self {
        let limit = defaults.integer(forKey: "fullSummaryChars")
        return Self(url: defaults.string(forKey: "baseURL").flatMap(storedEndpoint) ?? defaultURL,
                    model: defaults.string(forKey: "model") ?? defaultModel,
                    apiKey: environmentKey ?? defaults.string(forKey: "apiKey") ?? "",
                    summaryLimit: limit >= QueryInput.previewLimit ? limit : defaultSummaryLimit)
    }
}

struct ConnectionDraft: Equatable {
    var endpoint: String
    var model: String
    var savedKey: String
    var limit: String

    init(defaults: UserDefaults = .standard) {
        let current = ConnectionSettings.current(defaults: defaults)
        endpoint = defaults.string(forKey: "baseURL") ?? current.url.absoluteString
        model = current.model
        savedKey = defaults.string(forKey: "apiKey") ?? ""
        limit = String(current.summaryLimit)
    }

    func connection(environmentKey: String?) throws -> ConnectionSettings {
        guard let url = ConnectionSettings.endpoint(endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AskError(L("请输入包含主机名的 HTTP 或 HTTPS 接口地址。", "Enter a complete HTTP or HTTPS endpoint."))
        }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AskError(L("请输入模型名称。", "Enter a model name.")) }
        let key = environmentKey ?? savedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AskError(L("请输入 API Key。", "Enter an API key.")) }
        guard let count = Int(limit), count >= QueryInput.previewLimit else {
            throw AskError(L("全文上限至少为 2000 字。", "The full-summary limit must be at least 2000 characters."))
        }
        return ConnectionSettings(url: url, model: name, apiKey: key, summaryLimit: count)
    }

    func testConnection(environmentKey: String?, session: URLSession = .shared) async throws {
        let connection = try connection(environmentKey: environmentKey)
        let mode = PromptMode(key: "test", title: "", system: "Reply with OK.")
        _ = try await askLLM(QueryInput(preview: "OK"), mode: mode, connection: connection, session: session)
    }

    func save(to defaults: UserDefaults = .standard, environmentKey: String?) throws {
        let settings = try connection(environmentKey: environmentKey)
        defaults.set(settings.url.absoluteString, forKey: "baseURL")
        defaults.set(settings.model, forKey: "model")
        if environmentKey == nil { defaults.set(settings.apiKey, forKey: "apiKey") }
        defaults.set(settings.summaryLimit, forKey: "fullSummaryChars")
    }
}

struct ConnectionSettingsView: View {
    @State private var draft = ConnectionDraft()
    @State private var status = ""
    @State private var test: Task<Void, Never>?
    private let environmentKey = ProcessInfo.processInfo.environment["ASKAI_KEY"]
    let close: () -> Void

    var body: some View {
        Form {
            TextField(L("接口地址", "Endpoint"), text: $draft.endpoint)
            TextField(L("模型", "Model"), text: $draft.model)
            if environmentKey == nil {
                SecureField("API Key", text: $draft.savedKey)
            } else {
                LabeledContent("API Key", value: L("由 ASKAI_KEY 提供", "Provided by ASKAI_KEY"))
            }
            TextField(L("全文总结上限（字符）", "Full-summary limit (characters)"), text: $draft.limit)
            Text(status).font(.callout).lineLimit(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .help(status)
            HStack {
                Button(L("测试连接", "Test Connection"), action: checkConnection)
                    .disabled(test != nil)
                Spacer()
                Button(L("取消", "Cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(L("保存", "Save")) {
                    do {
                        try draft.save(environmentKey: environmentKey)
                        close()
                    } catch { status = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 510)
        .onChange(of: draft) { _ in resetTest() }
        .onDisappear { resetTest() }
    }

    private func resetTest() {
        test?.cancel()
        test = nil
        status = ""
    }

    private func checkConnection() {
        let candidate = draft
        status = L("正在测试…", "Testing…")
        test = Task { @MainActor in
            do {
                try await candidate.testConnection(environmentKey: environmentKey)
                guard !Task.isCancelled else { return }
                status = L("连接成功。", "Connection succeeded.")
            } catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription
            }
            test = nil
        }
    }
}

@MainActor
func makeSettingsWindow(close: @escaping () -> Void) -> NSWindow {
    let host = NSHostingController(rootView: ConnectionSettingsView(close: close))
    let window = NSWindow(contentViewController: host)
    window.title = L("AskAI 设置", "AskAI Settings")
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.setContentSize(host.view.fittingSize)
    return window
}
