import SwiftUI

struct AskError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// 常见服务商的 chat completions 地址，第一次配置时不用去翻文档。模型名各家变得快，不预填。
struct ProviderPreset: Identifiable, Equatable {
    let name: String
    let url: String
    var id: String { name }

    static let all: [ProviderPreset] = [
        ProviderPreset(name: "DeepSeek", url: "https://api.deepseek.com/chat/completions"),
        ProviderPreset(name: "OpenAI", url: "https://api.openai.com/v1/chat/completions"),
        ProviderPreset(name: "OpenRouter", url: "https://openrouter.ai/api/v1/chat/completions"),
        ProviderPreset(name: "Moonshot (Kimi)", url: "https://api.moonshot.cn/v1/chat/completions"),
        ProviderPreset(name: "Ollama (local)", url: "http://localhost:11434/v1/chat/completions"),
        ProviderPreset(name: "LM Studio (local)", url: "http://localhost:1234/v1/chat/completions"),
    ]

    /// 地址对应的预设；手动改过的地址不属于任何预设。
    static func matching(endpoint: String) -> ProviderPreset? {
        let text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.url == text }
    }
}

struct ConnectionSettings {
    static let defaultURL = URL(string: "https://api.deepseek.com/chat/completions")!
    static let defaultModel = "deepseek-chat"
    static let defaultSummaryLimit = 16_000
    static let defaultTemperature: Double = 0.3
    let url: URL
    let model: String
    let apiKey: String
    let summaryLimit: Int
    /// nil 表示不发送，用服务商的默认值：OpenAI 的推理模型（o 系列、GPT-5）对非默认值直接返回 400
    var temperature: Double? = defaultTemperature

    /// 本机回环地址上的服务（Ollama、LM Studio 等）不校验 Key，留空即可。
    static func isLocalEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    var isLocal: Bool { Self.isLocalEndpoint(url) }

    /// 能不能直接发请求：有 Key，或者是不需要 Key 的本机接口。
    var isConfigured: Bool { !apiKey.isEmpty || isLocal }

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

    /// 实际生效的 Key：ASKAI_KEY 优先，其次是 defaults。空字符串的环境变量当作没设置——
    /// 否则它会遮蔽已保存的 Key，而设置窗又因为“环境变量存在”不给输入框，用户无路可走。
    static func resolvedKey(environmentKey: String?, savedKey: String?) -> String {
        if let environmentKey, !environmentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return environmentKey
        }
        return savedKey ?? ""
    }

    /// ASKAI_KEY 是否真的提供了 Key（空字符串不算）。
    static func hasEnvironmentKey(_ environmentKey: String?) -> Bool {
        resolvedKey(environmentKey: environmentKey, savedKey: nil) != ""
    }

    /// defaults 里的 temperature：负数（约定写 -1）表示不发送。
    static func storedTemperature(defaults: UserDefaults) -> Double? {
        guard let number = defaults.object(forKey: "temperature") as? NSNumber else { return defaultTemperature }
        return number.doubleValue < 0 ? nil : number.doubleValue
    }

    static func current(defaults: UserDefaults = .standard,
                        environmentKey: String? = ProcessInfo.processInfo.environment["ASKAI_KEY"]) -> Self {
        let limit = defaults.integer(forKey: "fullSummaryChars")
        return Self(url: defaults.string(forKey: "baseURL").flatMap(storedEndpoint) ?? defaultURL,
                    model: defaults.string(forKey: "model") ?? defaultModel,
                    apiKey: resolvedKey(environmentKey: environmentKey, savedKey: defaults.string(forKey: "apiKey")),
                    summaryLimit: limit >= QueryInput.previewLimit ? limit : defaultSummaryLimit,
                    temperature: storedTemperature(defaults: defaults))
    }
}

/// 设置窗里的表单状态：接口相关的一部分加回答语言、历史开关。
struct ConnectionDraft: Equatable {
    var endpoint: String
    var model: String
    var savedKey: String
    var limit: String
    var temperature: String
    var answerLanguage: String      // "" 跟随界面，或 zh / en
    var savesHistory: Bool

    init(defaults: UserDefaults = .standard) {
        let current = ConnectionSettings.current(defaults: defaults)
        endpoint = defaults.string(forKey: "baseURL") ?? current.url.absoluteString
        model = current.model
        savedKey = defaults.string(forKey: "apiKey") ?? ""
        limit = String(current.summaryLimit)
        temperature = current.temperature.map { "\($0)" } ?? "-1"
        answerLanguage = AnswerLanguage.stored(defaults: defaults)?.rawValue ?? ""
        savesHistory = historySavingEnabled(defaults: defaults)
    }

    func connection(environmentKey: String?) throws -> ConnectionSettings {
        guard let url = ConnectionSettings.endpoint(endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AskError(L("请输入包含主机名的 HTTP 或 HTTPS 接口地址。", "Enter a complete HTTP or HTTPS endpoint."))
        }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AskError(L("请输入模型名称。", "Enter a model name.")) }
        let key = ConnectionSettings.resolvedKey(environmentKey: environmentKey,
                                                 savedKey: savedKey.trimmingCharacters(in: .whitespacesAndNewlines))
        // 本机接口（Ollama、LM Studio 等）不需要 Key，不必为了通过校验随便填一个
        guard !key.isEmpty || ConnectionSettings.isLocalEndpoint(url) else {
            throw AskError(L("请输入 API Key。", "Enter an API key."))
        }
        guard let count = Int(limit), count >= QueryInput.previewLimit else {
            throw AskError(L("全文上限至少为 2000 字。", "The full-summary limit must be at least 2000 characters."))
        }
        let degrees = Double(temperature.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let degrees, degrees == -1 || (0...2).contains(degrees) else {
            throw AskError(L("Temperature 需在 0 到 2 之间；填 -1 表示不发送，使用服务商默认值。",
                             "Temperature must be between 0 and 2; enter -1 to leave it to the provider."))
        }
        return ConnectionSettings(url: url, model: name, apiKey: key, summaryLimit: count,
                                  temperature: degrees < 0 ? nil : degrees)
    }

    func testConnection(environmentKey: String?, session: URLSession = .shared) async throws {
        let connection = try connection(environmentKey: environmentKey)
        let mode = PromptMode(key: "test", title: "", system: "Reply with OK.")
        _ = try await askLLM(QueryInput(preview: "OK"), mode: mode, connection: connection, session: session)
    }

    /// 校验通过后一次写回 defaults；有任何一项不合法就什么都不写。
    func save(to defaults: UserDefaults = .standard, environmentKey: String?) throws {
        let settings = try connection(environmentKey: environmentKey)
        guard ["", "zh", "en"].contains(answerLanguage) else {
            throw AskError(L("回答语言只能是「跟随界面」、zh 或 en。",
                             "Answer language must be follow-the-UI, zh or en."))
        }
        defaults.set(settings.url.absoluteString, forKey: "baseURL")
        defaults.set(settings.model, forKey: "model")
        if !ConnectionSettings.hasEnvironmentKey(environmentKey) { defaults.set(settings.apiKey, forKey: "apiKey") }
        defaults.set(settings.summaryLimit, forKey: "fullSummaryChars")
        defaults.set(settings.temperature ?? -1, forKey: "temperature")
        if answerLanguage.isEmpty {
            defaults.removeObject(forKey: "answerLanguage")
        } else {
            defaults.set(answerLanguage, forKey: "answerLanguage")
        }
        defaults.set(savesHistory, forKey: "saveHistory")
    }
}

struct ConnectionSettingsView: View {
    @State private var draft = ConnectionDraft()
    /// 选中的接口预设；空串表示自定义地址。
    @State private var preset = ProviderPreset.matching(endpoint: ConnectionDraft().endpoint)?.name ?? ""
    @State private var status = ""
    @State private var test: Task<Void, Never>?
    private let environmentKey = ProcessInfo.processInfo.environment["ASKAI_KEY"]
    let close: () -> Void

    var body: some View {
        Form {
            Section(L("接口", "Endpoint")) {
                Picker(L("预设", "Preset"), selection: $preset) {
                    Text(L("自定义", "Custom")).tag("")
                    ForEach(ProviderPreset.all) { Text($0.name).tag($0.name) }
                }
                .onChange(of: preset) { name in
                    if let chosen = ProviderPreset.all.first(where: { $0.name == name }) {
                        draft.endpoint = chosen.url
                    }
                }
                TextField(L("接口地址", "Endpoint"), text: $draft.endpoint)
                    .onChange(of: draft.endpoint) { endpoint in
                        preset = ProviderPreset.matching(endpoint: endpoint)?.name ?? ""
                    }
                TextField(L("模型", "Model"), text: $draft.model)
                if !ConnectionSettings.hasEnvironmentKey(environmentKey) {
                    SecureField("API Key", text: $draft.savedKey)
                        .help(L("本机接口（localhost）可以留空", "Optional for endpoints on localhost"))
                } else {
                    LabeledContent("API Key", value: L("由 ASKAI_KEY 提供", "Provided by ASKAI_KEY"))
                }
                TextField(L("全文总结上限（字符）", "Full-summary limit (characters)"), text: $draft.limit)
                TextField(L("Temperature（-1 = 不发送，用服务商默认值）", "Temperature (-1 = leave it to the provider)"),
                          text: $draft.temperature)
            }
            Section(L("问答", "Answers")) {
                Picker(L("回答语言", "Answer language"), selection: $draft.answerLanguage) {
                    Text(L("跟随界面", "Follow the UI")).tag("")
                    Text("简体中文").tag("zh")
                    Text("English").tag("en")
                }
                Toggle(L("保存历史记录", "Save history"), isOn: $draft.savesHistory)
            }
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
