import AppKit
import ServiceManagement

/// 常见服务商的 chat completions 地址，第一次配置时不用去翻文档。模型名各家变得快，不预填。
enum LaunchAtLogin {
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static var isEnabled: Bool { isAvailable && SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else { return }
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

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
    var explainBackground: String
    var savesHistory: Bool

    init(defaults: UserDefaults = .standard) {
        let current = ConnectionSettings.current(defaults: defaults)
        endpoint = defaults.string(forKey: "baseURL") ?? current.url.absoluteString
        model = current.model
        savedKey = defaults.string(forKey: "apiKey") ?? ""
        limit = String(current.summaryLimit)
        temperature = current.temperature.map { "\($0)" } ?? "-1"
        answerLanguage = AnswerLanguage.stored(defaults: defaults)?.rawValue ?? ""
        explainBackground = defaults.string(forKey: "explainBackground") ?? ""
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
        guard let count = Int(limit.trimmingCharacters(in: .whitespacesAndNewlines)), count >= QueryInput.previewLimit else {
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
        defaults.set(explainBackground.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "explainBackground")
        defaults.set(savesHistory, forKey: "saveHistory")
    }
}

@MainActor
private final class ConnectionSettingsViewController: NSViewController, NSTextFieldDelegate {
    private var draft = ConnectionDraft()
    private let environmentKey = ProcessInfo.processInfo.environment["ASKAI_KEY"]
    private let closeAction: () -> Void
    private var testTask: Task<Void, Never>?

    private let presetPopup = NSPopUpButton()
    private let endpointField = NSTextField()
    private let modelField = NSTextField()
    private let keyField = NSSecureTextField()
    private let limitField = NSTextField()
    private let temperatureField = NSTextField()
    private let backgroundField = NSComboBox()
    private let languagePopup = NSPopUpButton()
    private let saveHistoryCheckbox = NSButton(checkboxWithTitle: L("保存历史记录", "Save history"), target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: L("登录时自动启动", "Launch at login"), target: nil, action: nil)
    private let initialLaunchAtLogin = LaunchAtLogin.isEnabled
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton()

    init(close: @escaping () -> Void) {
        self.closeAction = close
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        presetPopup.addItem(withTitle: L("自定义", "Custom"))
        presetPopup.lastItem?.representedObject = ""
        for preset in ProviderPreset.all {
            presetPopup.addItem(withTitle: preset.name)
            presetPopup.lastItem?.representedObject = preset.name
        }
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)

        endpointField.stringValue = draft.endpoint
        endpointField.delegate = self
        modelField.stringValue = draft.model
        modelField.delegate = self
        limitField.stringValue = draft.limit
        limitField.delegate = self
        temperatureField.stringValue = draft.temperature
        temperatureField.delegate = self

        let keyControl: NSView
        if ConnectionSettings.hasEnvironmentKey(environmentKey) {
            let note = NSTextField(labelWithString: L("由 ASKAI_KEY 提供", "Provided by ASKAI_KEY"))
            note.textColor = .secondaryLabelColor
            keyControl = note
        } else {
            keyField.stringValue = draft.savedKey
            keyField.placeholderString = L("本机接口（localhost）可以留空", "Optional for endpoints on localhost")
            keyField.toolTip = keyField.placeholderString
            keyField.delegate = self
            keyControl = keyField
        }

        languagePopup.addItem(withTitle: L("跟随界面", "Follow the UI"))
        languagePopup.lastItem?.representedObject = ""
        languagePopup.addItem(withTitle: "简体中文")
        languagePopup.lastItem?.representedObject = "zh"
        languagePopup.addItem(withTitle: "English")
        languagePopup.lastItem?.representedObject = "en"
        if let idx = languagePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == draft.answerLanguage }) {
            languagePopup.selectItem(at: idx)
        }
        languagePopup.target = self
        languagePopup.action = #selector(fieldChanged)

        backgroundField.placeholderString = L("通用（可选择或输入背景）", "General (choose or type a background)")
        backgroundField.addItems(withObjectValues: ExplainCatalog.profiles.map { L($0.zh, $0.en) })
        backgroundField.stringValue = draft.explainBackground

        saveHistoryCheckbox.state = draft.savesHistory ? .on : .off
        saveHistoryCheckbox.target = self
        saveHistoryCheckbox.action = #selector(fieldChanged)

        launchAtLoginCheckbox.state = initialLaunchAtLogin ? .on : .off
        launchAtLoginCheckbox.isEnabled = LaunchAtLogin.isAvailable

        syncPresetSelection()

        func row(_ title: String, _ control: NSView) -> [NSView] {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.font = .systemFont(ofSize: 13)
            label.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return [label, control]
        }

        let separator = NSBox()
        separator.boxType = .separator

        let grid = NSGridView(views: [
            row(L("预设", "Preset"), presetPopup),
            row(L("接口地址", "Endpoint"), endpointField),
            row(L("模型", "Model"), modelField),
            row("API Key", keyControl),
            row(L("全文总结上限（字符）", "Full-summary limit (characters)"), limitField),
            row(L("Temperature（-1 = 不发送，用服务商默认值）", "Temperature (-1 = leave it to the provider)"), temperatureField),
        ])
        grid.columnSpacing = 12
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let answerGrid = NSGridView(views: [
            row(L("回答语言", "Answer language"), languagePopup),
            row(L("解释名词 · 读者背景", "Explain · Reader background"), backgroundField),
            row("", saveHistoryCheckbox),
            row("", launchAtLoginCheckbox),
        ])
        answerGrid.columnSpacing = 12
        answerGrid.rowSpacing = 10
        answerGrid.column(at: 0).xPlacement = .trailing
        answerGrid.column(at: 1).xPlacement = .leading

        answerGrid.cell(atColumnIndex: 1, rowIndex: 1).xPlacement = .fill

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = true
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        testButton.title = L("测试连接", "Test Connection")
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(checkConnection)

        let cancelButton = NSButton(title: L("取消", "Cancel"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let saveButton = NSButton(title: L("保存", "Save"), target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [testButton, spacer, cancelButton, saveButton])
        actions.alignment = .centerY
        actions.spacing = 8

        let stack = NSStackView(views: [grid, separator, answerGrid, statusLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 510),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            answerGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        resetTest()
    }

    private func syncDraftFromFields() {
        draft.endpoint = endpointField.stringValue
        draft.model = modelField.stringValue
        if !ConnectionSettings.hasEnvironmentKey(environmentKey) {
            draft.savedKey = keyField.stringValue
        }
        draft.limit = limitField.stringValue
        draft.temperature = temperatureField.stringValue
        draft.answerLanguage = languagePopup.selectedItem?.representedObject as? String ?? ""
        draft.explainBackground = backgroundField.stringValue
        draft.savesHistory = saveHistoryCheckbox.state == .on
    }

    private func syncPresetSelection() {
        let name = ProviderPreset.matching(endpoint: endpointField.stringValue)?.name ?? ""
        if let idx = presetPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == name }) {
            presetPopup.selectItem(at: idx)
        }
    }

    private func resetTest() {
        testTask?.cancel()
        testTask = nil
        testButton.isEnabled = true
        statusLabel.stringValue = ""
        statusLabel.toolTip = nil
    }

    @objc private func presetChanged() {
        if let name = presetPopup.selectedItem?.representedObject as? String,
           let preset = ProviderPreset.all.first(where: { $0.name == name }) {
            endpointField.stringValue = preset.url
        }
        resetTest()
    }

    @objc private func fieldChanged() {
        resetTest()
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === endpointField {
            syncPresetSelection()
        }
        resetTest()
    }

    @objc private func checkConnection() {
        syncDraftFromFields()
        let candidate = draft
        statusLabel.stringValue = L("正在测试…", "Testing…")
        statusLabel.toolTip = nil
        testButton.isEnabled = false
        testTask = Task { @MainActor in
            do {
                try await candidate.testConnection(environmentKey: environmentKey)
                guard !Task.isCancelled else { return }
                statusLabel.stringValue = L("连接成功。", "Connection succeeded.")
            } catch {
                guard !Task.isCancelled else { return }
                statusLabel.stringValue = error.localizedDescription
                statusLabel.toolTip = error.localizedDescription
            }
            testButton.isEnabled = true
            testTask = nil
        }
    }

    @objc private func cancel() {
        closeAction()
    }

    @objc private func save() {
        syncDraftFromFields()
        do {
            try draft.save(environmentKey: environmentKey)
            let wantLaunch = launchAtLoginCheckbox.state == .on
            if LaunchAtLogin.isAvailable, wantLaunch != initialLaunchAtLogin {
                try LaunchAtLogin.setEnabled(wantLaunch)
            }
            closeAction()
        } catch {
            statusLabel.stringValue = error.localizedDescription
            statusLabel.toolTip = error.localizedDescription
        }
    }
}

@MainActor
func makeSettingsWindow(close: @escaping () -> Void) -> NSWindow {
    let controller = ConnectionSettingsViewController(close: close)
    let window = NSWindow(contentViewController: controller)
    window.title = L("AskAI 设置", "AskAI Settings")
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    controller.view.layoutSubtreeIfNeeded()
    window.setContentSize(controller.view.fittingSize)
    return window
}
