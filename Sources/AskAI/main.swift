// AskAI —— macOS 划词问 AI 小工具
// 用法：在任意 App 里选中文字 → 按 ⌘⇧E → 弹窗显示 AI 对这个名词/术语的解释
//
// 权限说明（精确版）：
//   · 读剪贴板（NSPasteboard）本身【不需要】任何系统权限；
//   · 需要「辅助功能」权限的是【向别的 App 模拟 ⌘C】这一步（CGEvent）。
//     授权对象是"运行本工具的那个 App"，做一次即可：
//     - 用 AskAI.app 启动（推荐）：系统设置 → 隐私与安全性 → 辅助功能 → 添加 AskAI.app
//       授权绑定 app 本身，长期有效；
//     - 用 swift run 启动：授权的是终端 App，且终端一关进程就被杀，只适合调试。
//
// API Key 配置（二选一）：
//   defaults write com.dsh.AskAI apiKey sk-你的密钥   # .app 方式，写一次永久生效
//   export ASKAI_KEY=sk-你的密钥                      # 命令行调试方式
// 可选：换模型 defaults write com.dsh.AskAI model deepseek-reasoner

import AppKit
import ApplicationServices
import Carbon
import Darwin
import HotKey
import Vision

// MARK: - 配置

var defaults: UserDefaults { .standard }

// MARK: - 本地化（中文 / English）
// 默认跟随系统首选语言；可用 defaults write com.dsh.AskAI lang en 强制切换。

private enum Language {
    static let isChinese: Bool = {
        if let forced = defaults.string(forKey: "lang"), !forced.isEmpty {
            return forced.lowercased().hasPrefix("zh")
        }
        return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }()
}
var appIsChinese: Bool { Language.isChinese }

/// 双语取词：中文环境返回 zh，否则返回 en
func L(_ zh: String, _ en: String) -> String { appIsChinese ? zh : en }

// MARK: - 提示词模式

struct PromptMode {
    let key: String
    let title: String
    let system: String

    static let all: [PromptMode] = [
        PromptMode(key: "explain",
                   title: L("解释名词", "Explain"),
                   system: L(
                     "你是名词/术语解释助手，读者有计算机/数据库/软件工程背景。用户给出的通常是一个名词、术语或一小段文字。"
                   + "请用简体中文解释：如果原文是英文单词或术语，开头先给出它的中文翻译或对应说法；"
                   + "然后用一句话说清它是什么，再补充关键背景、机制或一个例子。"
                   + "技术术语优先按其领域含义解释（有歧义时点明），但不要预设具体技术栈、产品名或内部语境。"
                   + "不要翻译腔。控制在 150 字以内。",
                     "You explain terms for an engineer with a computer science / database / software engineering background. "
                   + "The user usually gives a single term or a short phrase. Start with a one-line plain definition, "
                   + "then add the key mechanism or a concrete example. Prefer the technical meaning of the term and call out "
                   + "ambiguity when it exists, but do not assume a specific stack, product or private context. "
                   + "Keep it under 120 words. Answer in English.")),
        PromptMode(key: "translate",
                   title: L("翻译", "Translate"),
                   system: L(
                     "你是翻译助手。把用户给出的文本翻译成简体中文；若原文本身是中文，则翻译成英文。"
                   + "只输出译文，不要解释、不要加引号或前缀。专业术语按通行译法。",
                     "You are a translator. Translate the user's text into English; if it is already English, translate it "
                   + "into Simplified Chinese. Output the translation only — no explanations, quotes or prefixes. "
                   + "Use conventional terminology.")),
        PromptMode(key: "summarize",
                   title: L("总结要点", "Summarize"),
                   system: L(
                     "你是摘要助手。用简体中文概括用户文本的核心要点，最多 3 条，每条一行，以「• 」开头。"
                   + "保留关键数字与结论，删除铺垫和重复。不要输出原文。",
                     "You summarize. Give at most 3 bullet points, one per line, each starting with \"• \". "
                   + "Keep key numbers and conclusions, drop filler and repetition. Do not restate the source. "
                   + "Answer in English.")),
        PromptMode(key: "code",
                   title: L("解释代码", "Explain Code"),
                   system: L(
                     "你是代码讲解助手。用简体中文解释用户给出的代码：先说它整体做什么，"
                   + "再按执行顺序说明关键语句的作用，最后指出可能的坑或副作用。控制在 200 字以内。",
                     "You explain code. Start with what it does overall, then walk through the key statements in "
                   + "execution order, and finish with pitfalls or side effects. Keep it under 160 words. Answer in English.")),
    ]
}



func currentMode() -> PromptMode {
    let key = defaults.string(forKey: "mode") ?? "explain"
    return PromptMode.all.first { $0.key == key } ?? PromptMode.all[0]
}

/// Older history entries stored the Chinese display title instead of the mode key.
func historyMode(_ key: String) -> PromptMode {
    let legacy = ["解释名词": "explain", "翻译": "translate", "总结要点": "summarize", "解释代码": "code"]
    return PromptMode.all.first { $0.key == (legacy[key] ?? key) || $0.title == key } ?? PromptMode.all[0]
}

// MARK: - 历史记录

struct HistoryEntry: Codable, Equatable {
    let time: Date
    let mode: String
    let source: String
    let answer: String
    var sentCharacters: Int? = nil
}

let historyKey = "history"
let historyLimit = 20

// 历史存文件而非 UserDefaults：避免 plist 膨胀，也便于用户自行删除/审计
let historyDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("AskAI", isDirectory: true)
let historyFile = historyDir.appendingPathComponent("history.json")

// history.json is atomically replaced. Lock a separate, persistent inode for every writer.
private func withHistoryLock<T>(_ operation: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
    let path = historyDir.appendingPathComponent("history.lock").path
    var fd: Int32
    repeat {
        fd = open(path, O_RDWR | O_CREAT | O_EXLOCK | O_CLOEXEC, 0o600)
    } while fd == -1 && errno == EINTR
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(fd) }
    return try operation()
}

private func readHistoryFile() throws -> [HistoryEntry] {
    do {
        let data = try Data(contentsOf: historyFile)
        return try JSONDecoder().decode([HistoryEntry].self, from: data)
    } catch CocoaError.fileReadNoSuchFile {
        return []
    }
}

private func saveHistory(_ entries: [HistoryEntry]) throws {
    let data = try JSONEncoder().encode(Array(entries.prefix(historyLimit)))
    try data.write(to: historyFile, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyFile.path)
}

/// Called under the history lock. Another process may have migrated these defaults already.
private func migrateLegacyHistoryIfNeeded() throws {
    guard defaults.object(forKey: historyKey) != nil else { return }
    defaults.synchronize()
    guard let raw = defaults.array(forKey: historyKey) as? [[String: Any]] else { return }
    let legacy: [HistoryEntry] = raw.compactMap { d in
        guard let t = d["time"] as? Double, let m = d["mode"] as? String,
              let s = d["source"] as? String, let a = d["answer"] as? String else { return nil }
        return HistoryEntry(time: Date(timeIntervalSince1970: t), mode: m, source: s, answer: a)
    }
    if !legacy.isEmpty {
        let existing = try readHistoryFile()
        try saveHistory(existing + legacy.filter { !existing.contains($0) })
    }
    defaults.removeObject(forKey: historyKey)
    defaults.synchronize()
}

func loadHistory() -> [HistoryEntry] {
    do {
        return try withHistoryLock {
            try migrateLegacyHistoryIfNeeded()
            return try readHistoryFile()
        }
    } catch {
        NSLog("AskAI: failed to load history: \(error.localizedDescription)")
        return []
    }
}

func clearHistoryStorage() {
    do {
        try withHistoryLock {
            if FileManager.default.fileExists(atPath: historyFile.path) {
                try FileManager.default.removeItem(at: historyFile)
            }
            defaults.removeObject(forKey: historyKey)
            defaults.synchronize()
        }
    } catch {
        NSLog("AskAI: failed to clear history: \(error.localizedDescription)")
    }
}

func appendHistory(mode: String, source: String, answer: String, sentCharacters: Int? = nil) throws {
    guard !answer.isEmpty, !answer.hasPrefix("❌") else { return }
    try withHistoryLock {
        try migrateLegacyHistoryIfNeeded()
        var list = try readHistoryFile()
        list.insert(HistoryEntry(time: Date(), mode: mode, source: source, answer: answer, sentCharacters: sentCharacters), at: 0)
        try saveHistory(list)
    }
}

// 快捷键配置（默认 ⌘⇧E；用菜单栏 🤖 →「设置快捷键…」改，自动存进 defaults）
let defaultHotKeyCode = UInt32(kVK_ANSI_E)
let defaultHotKeyMods = UInt(NSEvent.ModifierFlags.command.union(.shift).rawValue)
let hotkeyKeyCode = UInt32(defaults.object(forKey: "hotkeyKey") as? Int ?? Int(defaultHotKeyCode))
let hotkeyModsRaw = UInt(defaults.object(forKey: "hotkeyMods") as? Int ?? Int(defaultHotKeyMods))
let hotkeyText = defaults.string(forKey: "hotkeyDesc") ?? "⌘⇧E"

func makeHotKey(keyCode: UInt32, mods: NSEvent.ModifierFlags, handler: @escaping () -> Void) -> HotKey? {
    guard Key(carbonKeyCode: keyCode) != nil else { return nil }
    return HotKey(keyCombo: KeyCombo(carbonKeyCode: keyCode, carbonModifiers: mods.carbonFlags),
                  keyDownHandler: handler)
}

// MARK: - 2. 调用 LLM（OpenAI Chat Completions 格式）

func askLLM(_ input: QueryInput, mode: PromptMode, connection: ConnectionSettings,
            session: URLSession = .shared, onDelta: ((String) async -> Void)? = nil) async throws -> String {
    guard !connection.apiKey.isEmpty else {
        throw AskError(L("未配置 API Key。请打开菜单栏设置或指定 ASKAI_KEY。",
                         "No API key configured. Open Settings in the menu bar or set ASKAI_KEY."))
    }
    var req = URLRequest(url: connection.url)
    req.httpMethod = "POST"
    req.timeoutInterval = 60
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization")

    let streaming = onDelta != nil
    var body: [String: Any] = [
        "model": connection.model,
        "temperature": 0.3,
        "messages": [
            ["role": "system", "content": mode.system],
            ["role": "user", "content": input.message],
        ],
    ]
    if streaming { body["stream"] = true }
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    guard let onDelta else {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AskAI", code: code,
                          userInfo: [NSLocalizedDescriptionKey: L("API 出错 (\(code)): \(errBody.prefix(200))", "API error (\(code)): \(errBody.prefix(200))")])
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = root?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard let content = message?["content"] as? String, !content.isEmpty else {
            throw NSError(domain: "AskAI", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L("响应里没有 content", "Response contained no content")])
        }
        return content
    }

    // 流式：逐行解析 SSE，边到边刷新
    let (bytes, resp) = try await session.bytes(for: req)
    return try await withTaskCancellationHandler {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            // 读取有限量错误信息后立即跳出：不让序列继续挂起等待
            var raw = ""
            var lines = 0
            for try await line in bytes.lines {
                raw += line
                lines += 1
                if raw.count > 300 || lines > 20 { break }
            }
            throw NSError(domain: "AskAI", code: code,
                          userInfo: [NSLocalizedDescriptionKey: L("API 出错 (\(code)): \(raw.prefix(200))", "API error (\(code)): \(raw.prefix(200))")])
        }

        return try await readChatStream(bytes.lines, onDelta: onDelta)
    } onCancel: {
        bytes.task.cancel()
    }
}

func readChatStream<Lines: AsyncSequence>(_ lines: Lines, onDelta: (String) async -> Void) async throws -> String
where Lines.Element == String {
    var full = ""
    var finished = false
    for try await line in lines {
        try Task.checkCancellation()
        guard line.hasPrefix("data:") else { continue }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            finished = true
            break
        }
        guard !payload.isEmpty else { continue }
        let obj = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        if let error = obj?["error"], !(error is NSNull) {
            let message = (error as? [String: Any])?["message"] as? String
            throw NSError(domain: "AskAI", code: 3, userInfo: [NSLocalizedDescriptionKey:
                message ?? L("服务端报告流式请求失败", "The server reported a streaming error")])
        }
        guard let choices = obj?["choices"] as? [[String: Any]], let choice = choices.first else { continue }
        if let delta = choice["delta"] as? [String: Any], let piece = delta["content"] as? String, !piece.isEmpty {
            full += piece
            await onDelta(full)
        }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            guard reason == "stop" else {
                throw NSError(domain: "AskAI", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    L("生成提前结束（\(reason)）", "Generation ended early (\(reason))")])
            }
            finished = true
        }
    }
    guard finished else {
        throw NSError(domain: "AskAI", code: 3, userInfo: [NSLocalizedDescriptionKey:
            L("连接在服务端确认完成前关闭", "Connection closed before the server confirmed completion")])
    }
    guard !full.isEmpty else {
        throw NSError(domain: "AskAI", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: L("流式响应没有内容", "Empty streaming response")])
    }
    return full
}

// MARK: - 2.5 OCR：截图选区 → 识别文字（用于图片里不可复制的词）

func captureRegion() -> URL? {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("askai-shot-\(UUID().uuidString).png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-i", "-x", "-t", "png", url.path]   // -i 交互选区，-x 静音
    do { try task.run() } catch { return nil }
    task.waitUntilExit()
    // 用户按 Esc 取消时不会产生文件
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

func ocrText(from url: URL) -> String? {
    defer { try? FileManager.default.removeItem(at: url) }
    guard let img = NSImage(contentsOf: url),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])

    let text = (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

// MARK: - 4. 菜单栏常驻 + 全局快捷键（快捷键可在菜单里自己录）

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?   // 必须强引用！局部变量会被立即释放，图标就没了
    private var infoItem: NSMenuItem?
    private var setHotkeyItem: NSMenuItem?
    private var recorderPanel: NSPanel?
    private var keyMonitor: Any?
    private var recording = false
    private var settingsWindow: NSWindow?
    private var lastPanel: ResultPanel?        // 记住上一个结果窗，新结果出来时先关掉
    private var escMonitor: Any?           // 结果窗显示期间监听全局 Esc，保证一定能关

    private var hotkeyDesc: String { defaults.string(forKey: "hotkeyDesc") ?? "⌘⇧E" }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "🤖"

        let menu = NSMenu()
        let info = NSMenuItem(title: L("选中文字后按 \(hotkeyDesc) 询问 AI", "Select text, then press \(hotkeyDesc)"), action: nil, keyEquivalent: "")
        infoItem = info
        menu.addItem(info)
        menu.addItem(.separator())

        // 模式切换（单选）
        let modeMenu = NSMenu()
        for m in PromptMode.all {
            let it = NSMenuItem(title: m.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.key
            modeMenu.addItem(it)
        }
        let modeItem = NSMenuItem(title: L("模式", "Mode"), action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // 历史记录（子菜单，点条目直接回看）
        let histItem = NSMenuItem(title: L("历史记录", "History"), action: nil, keyEquivalent: "")
        histItem.submenu = NSMenu()
        menu.addItem(histItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("设置…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let setHotkey = NSMenuItem(title: L("设置快捷键…（当前 \(hotkeyDesc)）", "Set Hotkey… (now \(hotkeyDesc))"),
                                   action: #selector(openRecorder), keyEquivalent: "")
        setHotkey.target = self
        setHotkeyItem = setHotkey
        menu.addItem(setHotkey)

        let shot = NSMenuItem(title: L("截图解释…（图片里的文字）", "Explain from Screen… (text in images)"),
                              action: #selector(askFromScreen), keyEquivalent: "")
        shot.target = self
        menu.addItem(shot)

        // 重启：同一二进制重开，不会丢辅助功能授权（重建才会丢）
        let restart = NSMenuItem(title: L("重启 AskAI", "Restart AskAI"), action: #selector(relaunch), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)

        let auth = NSMenuItem(title: L("打开辅助功能设置…", "Open Accessibility Settings…"),
                              action: #selector(openAccessibilitySettings), keyEquivalent: "")
        auth.target = self
        menu.addItem(auth)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("退出", "Quit"), action: #selector(NSApplication.terminate(_:)),
                               keyEquivalent: "q"))
        statusItem?.menu = menu
        menu.delegate = self
        refreshMenu()

        registerHotKey()
        if ConnectionSettings.current().apiKey.isEmpty { openSettings() }
        else { promptForAccessibilityIfNeeded() }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = makeSettingsWindow { [weak self] in self?.settingsWindow?.close() }
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// 每次打开菜单时刷新勾选状态与历史条目
    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        let cur = currentMode().key
        for item in menu.items where item.submenu !== statusItem?.menu {
            if let sub = item.submenu, item.title == L("模式", "Mode") {
                for m in sub.items { m.state = (m.representedObject as? String) == cur ? .on : .off }
            }
        }
        if let hist = menu.items.first(where: { $0.title == L("历史记录", "History") })?.submenu {
            hist.removeAllItems()
            let list = loadHistory()
            if list.isEmpty {
                let empty = NSMenuItem(title: L("（暂无记录）", "(none)"), action: nil, keyEquivalent: "")
                empty.isEnabled = false
                hist.addItem(empty)
            } else {
                for h in list {
                    let t = h.source.replacingOccurrences(of: "\n", with: " ")
                    let label = t.count > 24 ? String(t.prefix(24)) + "…" : t
                    let it = NSMenuItem(title: label, action: #selector(showHistory(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = h
                    hist.addItem(it)
                }
                hist.addItem(NSMenuItem.separator())
                let clear = NSMenuItem(title: L("清空历史", "Clear History"), action: #selector(clearHistory), keyEquivalent: "")
                clear.target = self
                hist.addItem(clear)
            }
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(key, forKey: "mode")
        refreshMenu()
    }

    @objc private func showHistory(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry else { return }
        let panel = presentResult(source: entry.source)
        panel.show(entry)
    }

    @objc private func clearHistory() {
        clearHistoryStorage()
        refreshMenu()
    }

    // MARK: 重启与授权入口

    /// 用 -n 强制启动新实例，等 LaunchServices 接收请求后再退出当前实例（避免竞态）；
    /// 启动失败则保持运行，不会出现"旧的一退、新的一直没起来"。
    /// 同一二进制重启不会改变签名，所以辅助功能授权保持不变。
    @objc private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try task.run()
        } catch {
            NSSound.beep()
            return
        }
        task.waitUntilExit()

        // 再确认新实例真的起来了（除了自己还有同 bundle id 的进程）才退出，
        // 最多等 2 秒；没起来就保持运行，绝不出现"旧的退了新的没有"。
        let bundleID = Bundle.main.bundleIdentifier ?? "com.dsh.AskAI"
        var newInstanceUp = false
        for _ in 0..<10 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
                newInstanceUp = true
                break
            }
            usleep(200_000)
        }
        if newInstanceUp {
            NSApp.terminate(nil)
        } else {
            NSSound.beep()
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 未授权时弹系统对话框，并直接打开「隐私与安全性 → 辅助功能」，
    /// 免得用户在系统设置里找不到入口。
    private func promptForAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func registerHotKey() {
        infoItem?.title = L("选中文字后按 \(hotkeyDesc) 询问 AI", "Select text, then press \(hotkeyDesc)")
        setHotkeyItem?.title = L("设置快捷键…（当前 \(hotkeyDesc)）", "Set Hotkey… (now \(hotkeyDesc))")
        let code = UInt32(defaults.object(forKey: "hotkeyKey") as? Int ?? Int(defaultHotKeyCode))
        let raw = UInt(defaults.object(forKey: "hotkeyMods") as? Int ?? Int(defaultHotKeyMods))
        let mods = NSEvent.ModifierFlags(rawValue: raw)
        hotKey = makeHotKey(keyCode: code, mods: mods) { [weak self] in
            self?.ask()
        }
    }

    private var capturingSelection = false

    private func ask() {
        guard !recording, !capturingSelection else { return }
        guard !ConnectionSettings.current().apiKey.isEmpty else { openSettings(); return }
        capturingSelection = true
        Task { @MainActor in
            defer { capturingSelection = false }
            do {
                if let text = try await selectedText() {
                    runQuery(source: text)
                } else {
                    askFromScreen()
                }
            } catch { /* Focus changed or capture was cancelled. */ }
        }
    }

    /// 截图选区 → OCR → 解释
    @objc private func askFromScreen() {
        guard !ConnectionSettings.current().apiKey.isEmpty else { openSettings(); return }
        guard let shot = captureRegion() else { return }   // 取消截图则静默返回
        guard let text = ocrText(from: shot) else {
            let alert = NSAlert()
            alert.messageText = L("没有识别到文字", "No text found")
            alert.informativeText = L("选区内未检测到可识别的文本，请重新框选。", "No recognizable text in that region. Try selecting it again.")
            alert.runModal()
            return
        }
        runQuery(source: text)
    }

    private func runQuery(source: String) {
        presentResult(source: source).request(mode: currentMode())
    }

    private func presentResult(source: String) -> ResultPanel {
        lastPanel?.close()
        let panel = ResultPanel(source: source)
        panel.delegate = self
        lastPanel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        startEscMonitor()
        return panel
    }

    // MARK: 快捷键录制窗口

    @objc private func openRecorder() {
        if recorderPanel != nil { return }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 140),
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = L("设置快捷键", "Set Hotkey")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let label = NSTextField(labelWithString: L("按下新的快捷键组合\n需至少包含一个修饰键，Esc 取消", "Press the new shortcut\nAt least one modifier is required; Esc to cancel"))
        label.alignment = .center
        label.font = .systemFont(ofSize: 14)
        label.frame = NSRect(x: 20, y: 20, width: 360, height: 90)
        label.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(label)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        recorderPanel = panel
        recording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === panel else { return event }
            return self.handleRecorderKey(event)
        }
    }

    private func handleRecorderKey(_ event: NSEvent) -> NSEvent? {
        let code = event.keyCode
        if code == UInt16(kVK_Escape) { closeRecorder(); return nil }

        // 单独的修饰键不算有效组合
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if modifierKeyCodes.contains(code) { return nil }

        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.isEmpty else { return nil }                  // 至少一个修饰键
        guard Key(carbonKeyCode: UInt32(code)) != nil else {     // 该键不受支持就提示，不改配置
            (recorderPanel?.contentView?.subviews.first as? NSTextField)?.stringValue =
                L("这个按键暂不支持，请换一个组合", "That key is not supported; try another combination")
            return nil
        }

        let desc = modifierSymbols(mods) + keyLabel(event)
        defaults.set(Int(code), forKey: "hotkeyKey")
        defaults.set(Int(mods.rawValue), forKey: "hotkeyMods")
        defaults.set(desc, forKey: "hotkeyDesc")
        registerHotKey()
        closeRecorder()
        return nil
    }

    private func modifierSymbols(_ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s
    }

    private func keyLabel(_ event: NSEvent) -> String {
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return chars.uppercased()
        }
        return L("键\(event.keyCode)", "Key\(event.keyCode)")
    }

    private func closeRecorder() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        recording = false
        recorderPanel?.close()
        recorderPanel = nil
    }

    // MARK: 结果窗的生命周期

    /// 全局监听 Esc：结果窗不一定是 key window，用系统级监听兜底，保证一定能关。
    private func startEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            DispatchQueue.main.async { self?.lastPanel?.close() }
        }
    }

    private func stopEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
            lastPanel?.refreshSummaryLimit()
            if !ConnectionSettings.current().apiKey.isEmpty { promptForAccessibilityIfNeeded() }
        }
        if window === recorderPanel {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            recording = false
            recorderPanel = nil
        }
        if window === lastPanel {
            stopEscMonitor()
            lastPanel = nil
        }
    }
}

// MARK: - 配置自检：AskAI.app/Contents/MacOS/AskAI --check
// 用来确认「defaults 里写的 Key」和「App 实际读的域」是同一个，避免静默失效。

if CommandLine.arguments.contains("--check") {
    let connection = ConnectionSettings.current()
    let bundleID = Bundle.main.bundleIdentifier ?? L("(未在 .app 内运行)", "(not running inside a .app)")
    let envKey = ProcessInfo.processInfo.environment["ASKAI_KEY"]
    let defaultsKey = defaults.string(forKey: "apiKey")
    let yes = L("已设置", "set")
    let no  = L("未设置", "not set")
    print(L("bundle id        : ", "bundle id        : ") + bundleID)
    print(L("defaults 域      : ", "defaults domain  : ") + bundleID)
    print("env ASKAI_KEY    : " + (envKey == nil ? no : "\(yes) (\(envKey!.count) chars)"))
    print("defaults apiKey  : " + (defaultsKey == nil ? no : "\(yes) (\(defaultsKey!.count) chars)"))
    print(L("优先级           : env ASKAI_KEY > defaults apiKey", "precedence       : env ASKAI_KEY > defaults apiKey"))
    print(L("生效模型         : ", "model            : ") + connection.model)
    print(L("接口地址         : ", "endpoint         : ") + connection.url.absoluteString)
    if let bad = defaults.string(forKey: "baseURL"), ConnectionSettings.storedEndpoint(bad) == nil {
        print(L("⚠️ baseURL 配置「\(bad)」无效（应为完整 https:// 地址），已回落默认地址",
               "⚠️ configured baseURL '\(bad)' is invalid (expected a full https:// URL); using the default"))
    }
    print(L("快捷键           : ", "hotkey           : ") + hotkeyText)
    print(L("界面语言         : ", "ui language      : ") + (appIsChinese ? "zh-CN" : "en"))
    print(L("辅助功能授权     : ", "accessibility    : ")
          + (AXIsProcessTrusted() ? L("已授权", "granted") : L("未授权（模拟 ⌘C 会失败）", "NOT granted (⌘C simulation will fail)")))
    exit(0)
}

// MARK: - 命令行问答：AskAI --ask "要解释的文字"
// 用于端到端自测（真发一次请求 + 真实写历史），也可当作脚本工具使用。

if let i = CommandLine.arguments.firstIndex(of: "--ask") {
    guard i + 1 < CommandLine.arguments.count else {
        fputs(L("用法：AskAI --ask <文字>\n", "Usage: AskAI --ask <text>\n"), stderr)
        exit(EXIT_FAILURE)
    }
    let question = CommandLine.arguments[i + 1]
    let mode = currentMode()
    Task {
        do {
            let input = QueryInput(preview: question)
            let answer = try await askLLM(input, mode: mode, connection: .current())
            print(answer)
            try appendHistory(mode: mode.key, source: question, answer: answer)

            let attrs = try? FileManager.default.attributesOfItem(atPath: historyFile.path)
            let perms = (attrs?[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) }
            print("---")
            print(L("历史文件 : ", "history file : ") + historyFile.path)
            print(L("文件权限 : ", "file mode    : ") + (perms ?? L("文件不存在", "missing")))
            print(L("记录条数 : ", "entries      : ") + "\(loadHistory().count)")
            print(L("可解析   : ", "json round-trip : ") + (try readHistoryFile().isEmpty ? L("否", "failed") : L("是", "ok")))
        } catch {
            fputs(L("错误: ", "error: ") + error.localizedDescription + "\n", stderr)
            exit(EXIT_FAILURE)
        }
        exit(EXIT_SUCCESS)
    }
    dispatchMain()
}

// MARK: - 入口

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
